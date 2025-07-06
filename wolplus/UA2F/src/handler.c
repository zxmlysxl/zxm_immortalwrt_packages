#include "assert.h"
#include "handler.h"
#include "cache.h"
#include "custom.h"
#include "statistics.h"
#include "util.h"

#ifdef UA2F_ENABLE_UCI
#include "config.h"
#endif

#include <arpa/inet.h>
#include <libnetfilter_queue/libnetfilter_queue_ipv4.h>
#include <libnetfilter_queue/libnetfilter_queue_ipv6.h>
#include <libnetfilter_queue/libnetfilter_queue_tcp.h>
#include <libnetfilter_queue/pktbuff.h>
#include <linux/if_ether.h>

#define MAX_USER_AGENT_LENGTH (0xffff + (MNL_SOCKET_BUFFER_SIZE / 2))
static char *replacement_user_agent_string = NULL;

#define USER_AGENT_MATCH "\r\nUser-Agent:"
#define USER_AGENT_MATCH_LENGTH 13

#define CONNMARK_ESTIMATE_LOWER 16
#define CONNMARK_ESTIMATE_UPPER 32
#define CONNMARK_ESTIMATE_VERDICT 33

#define CONNMARK_NOT_HTTP 43
#define CONNMARK_HTTP 44

#ifndef UA2F_NO_CACHE
bool use_conntrack = true;
#else
bool use_conntrack = false;
#endif

static bool cache_initialized = false;

void init_handler() {
    replacement_user_agent_string = malloc(MAX_USER_AGENT_LENGTH);
    assert(replacement_user_agent_string != NULL && "Failed to allocate user agent string");

    bool ua_set = false;

#ifdef UA2F_ENABLE_UCI
    if (config.use_custom_ua) {
        memset(replacement_user_agent_string, ' ', MAX_USER_AGENT_LENGTH);
        strncpy(replacement_user_agent_string, config.custom_ua, strlen(config.custom_ua));
        syslog(LOG_INFO, "Using config user agent string: %s", replacement_user_agent_string);
        ua_set = true;
    }

    if (config.disable_connmark) {
        use_conntrack = false;
        syslog(LOG_INFO, "Conntrack cache disabled by config.");
    }
#endif

#ifdef UA2F_CUSTOM_UA
    if (!ua_set) {
        memset(replacement_user_agent_string, ' ', MAX_USER_AGENT_LENGTH);
        strncpy(replacement_user_agent_string, UA2F_CUSTOM_UA, strlen(UA2F_CUSTOM_UA));
        syslog(LOG_INFO, "Using embed user agent string: %s", replacement_user_agent_string);
        ua_set = true;
    }
#endif

    if (!ua_set) {
        memset(replacement_user_agent_string, 'F', MAX_USER_AGENT_LENGTH);
        syslog(LOG_INFO, "Custom user agent string not set, using default F-string.");
    }

    syslog(LOG_INFO, "Handler initialized.");
}

struct mark_op {
    bool should_set;
    uint32_t mark;
};

void send_verdict(const struct nf_queue *queue, const struct nf_packet *pkt, const struct mark_op mark,
                  struct pkt_buff *mangled_pkt_buff) {
    assert(queue != NULL && "Queue cannot be NULL");
    assert(pkt != NULL && "Packet cannot be NULL");
    assert(queue->nl_socket != NULL && "Netlink socket cannot be NULL");

    struct nlmsghdr *nlh = nfqueue_put_header(pkt->queue_num, NFQNL_MSG_VERDICT);
    if (nlh == NULL) {
        syslog(LOG_ERR, "failed to put nfqueue header");
        goto end;
    }
    nfq_nlmsg_verdict_put(nlh, (int)pkt->packet_id, NF_ACCEPT);

    if (mark.should_set) {
        struct nlattr *nest = mnl_attr_nest_start_check(nlh, SEND_BUF_LEN, NFQA_CT);
        if (nest == NULL) {
            syslog(LOG_ERR, "failed to put nfqueue attr");
            goto end;
        }
        if (!mnl_attr_put_u32_check(nlh, SEND_BUF_LEN, CTA_MARK, htonl(mark.mark))) {
            syslog(LOG_ERR, "failed to put nfqueue attr");
            goto end;
        }
        mnl_attr_nest_end(nlh, nest);
    }

    if (mangled_pkt_buff != NULL) {
        assert(pktb_data(mangled_pkt_buff) != NULL && "Mangled packet data cannot be NULL");
        assert(pktb_len(mangled_pkt_buff) > 0 && "Mangled packet length must be positive");
        nfq_nlmsg_verdict_put_pkt(nlh, pktb_data(mangled_pkt_buff), pktb_len(mangled_pkt_buff));
    }

    const __auto_type ret = mnl_socket_sendto(queue->nl_socket, nlh, nlh->nlmsg_len);
    if (ret == -1) {
        syslog(LOG_ERR, "failed to send verdict: %s", strerror(errno));
    }

end:
    if (nlh != NULL) {
        free(nlh);
    }
}

void add_to_cache(const struct nf_packet *pkt) {
    const struct addr_port target = {
        .addr = pkt->orig.dst,
        .port = pkt->orig.dst_port,
    };

    cache_add(target);
}

struct mark_op get_next_mark(const struct nf_packet *pkt, const bool has_ua) {
    if (!use_conntrack || !pkt->has_conntrack) {
        return (struct mark_op){false, 0};
    }

    // I didn't think this will happen, but just in case
    // firewall should already have a rule to return all marked with CONNMARK_NOT_HTTP packets
    if (pkt->conn_mark == CONNMARK_NOT_HTTP) {
        syslog(LOG_WARNING, "Packet has already been marked as not http. Maybe firewall rules are wrong?");
        return (struct mark_op){false, 0};
    }

    if (pkt->conn_mark == CONNMARK_HTTP) {
        return (struct mark_op){false, 0};
    }

    if (has_ua) {
        return (struct mark_op){true, CONNMARK_HTTP};
    }

    if (!pkt->has_connmark || pkt->conn_mark == 0) {
        return (struct mark_op){true, CONNMARK_ESTIMATE_LOWER};
    }

    if (pkt->conn_mark == CONNMARK_ESTIMATE_VERDICT) {
        add_to_cache(pkt);
        return (struct mark_op){true, CONNMARK_NOT_HTTP};
    }

    if (pkt->conn_mark >= CONNMARK_ESTIMATE_LOWER && pkt->conn_mark <= CONNMARK_ESTIMATE_UPPER) {
        return (struct mark_op){true, pkt->conn_mark + 1};
    }

    syslog(LOG_WARNING, "Unexpected connmark value: %d, Maybe other program has changed connmark?", pkt->conn_mark);
    return (struct mark_op){true, pkt->conn_mark + 1};
}

bool should_ignore(const struct nf_packet *pkt) {
    bool retval = false;
    struct addr_port target = {
        .addr = pkt->orig.dst,
        .port = pkt->orig.dst_port,
    };

    retval = cache_contains(target);

    return retval;
}

enum {
    IP_UNK = 0,
};

bool ipv4_set_transport_header(struct pkt_buff *pkt_buff) {
    struct iphdr *ip_hdr = nfq_ip_get_hdr(pkt_buff);
    if (ip_hdr == NULL) {
        syslog(LOG_ERR, "Failed to get ipv4 ip header");
        return false;
    }

    if (nfq_ip_set_transport_header(pkt_buff, ip_hdr) == -1) {
        syslog(LOG_ERR, "Failed to set ipv4 transport header");
        return false;
    }
    return true;
}

bool ipv6_set_transport_header(struct pkt_buff *pkt_buff) {
    struct ip6_hdr *ip_hdr = nfq_ip6_get_hdr(pkt_buff);
    if (ip_hdr == NULL) {
        syslog(LOG_ERR, "Failed to get ipv6 ip header");
        return false;
    }

    if (nfq_ip6_set_transport_header(pkt_buff, ip_hdr, IPPROTO_TCP) == 0) {
        syslog(LOG_ERR, "Failed to set ipv6 transport header");
        return false;
    }
    return true;
}

int get_pkt_ip_version(const struct nf_packet *pkt) {
    if (pkt->has_conntrack) {
        return pkt->orig.ip_version;
    }

    switch (pkt->hw_protocol) {
    case ETH_P_IP:
        return IPV4;
    case ETH_P_IPV6:
        return IPV6;
    default:
        syslog(LOG_WARNING, "Received unknown ip packet %x.", pkt->hw_protocol);
        return IP_UNK;
    }
}

void handle_packet(const struct nf_queue *queue, const struct nf_packet *pkt) {
    assert(queue != NULL && "Queue cannot be NULL");
    assert(pkt != NULL && "Packet cannot be NULL");
    assert(pkt->payload != NULL && "Packet payload cannot be NULL");
    assert(pkt->payload_len > 0 && "Packet payload length must be positive");

    bool ct_ok = use_conntrack && pkt->has_conntrack;

    if (ct_ok) {
        if (!cache_initialized) {
            init_not_http_cache(60);
            cache_initialized = true;
        }
    }

    assert((!ct_ok || cache_initialized) && "Cache must be initialized when using conntrack");

    if (ct_ok && should_ignore(pkt)) {
        send_verdict(queue, pkt, (struct mark_op){true, CONNMARK_NOT_HTTP}, NULL);
        goto end;
    }

    struct pkt_buff *pkt_buff = pktb_alloc(AF_INET, pkt->payload, pkt->payload_len, 0);
    if (pkt_buff == NULL) {
        syslog(LOG_ERR, "Failed to allocate packet buffer");
        goto end;
    }

    assert(pktb_data(pkt_buff) != NULL && "Packet buffer data cannot be NULL");
    assert(pktb_len(pkt_buff) > 0 && "Packet buffer length must be positive");

    const int type = get_pkt_ip_version(pkt);
    assert((type == IPV4 || type == IPV6 || type == IP_UNK) && "Invalid IP version");
    if (type == IP_UNK) {
        // will this happen?
        syslog(LOG_WARNING, "Received unknown ip packet type %x. You may set wrong firewall rules.", pkt->hw_protocol);
        send_verdict(queue, pkt, get_next_mark(pkt, false), NULL);
        goto end;
    }

    if (type == IPV4) {
        if (!ipv4_set_transport_header(pkt_buff)) {
            syslog(LOG_ERR, "Failed to set ipv4 transport header");
            goto end;
        }
        count_ipv4_packet();
    } else if (type == IPV6) {
        if (!ipv6_set_transport_header(pkt_buff)) {
            syslog(LOG_ERR, "Failed to set ipv6 transport header");
            goto end;
        }
        count_ipv6_packet();
    } else {
        syslog(LOG_ERR, "Unknown ip version");
        goto end;
    }

    if (pktb_transport_header(pkt_buff) == NULL) {
        char msg[300];
        if (type == IPV4) {
            syslog(LOG_WARNING, "Failed to set ipv4 transport header.");
            const __auto_type ip_hdr = nfq_ip_get_hdr(pkt_buff);
            if (ip_hdr != NULL) {
                nfq_ip_snprintf(msg, sizeof(msg), ip_hdr);
            } else {
                syslog(LOG_WARNING, "Failed to get ipv4 ip header");
                goto end;
            }
        } else {
            syslog(LOG_WARNING, "Failed to set ipv6 transport header.");
            const __auto_type ip_hdr = nfq_ip6_get_hdr(pkt_buff);
            if (ip_hdr != NULL) {
                nfq_ip6_snprintf(msg, sizeof(msg), ip_hdr);
            } else {
                syslog(LOG_WARNING, "Failed to get ipv6 ip header");
                goto end;
            }
        }
        syslog(LOG_WARNING, "Header: %s", msg);
        goto end;
    }

    const __auto_type tcp_hdr = nfq_tcp_get_hdr(pkt_buff);
    if (tcp_hdr == NULL) {
        // This packet is not tcp, pass it
        syslog(LOG_WARNING, "No tcp header found");
        send_verdict(queue, pkt, (struct mark_op){false, 0}, NULL);
        goto end;
    }

    const __auto_type tcp_payload = nfq_tcp_get_payload(tcp_hdr, pkt_buff);
    if (tcp_payload == NULL) {
        syslog(LOG_WARNING, "No tcp payload found");
        send_verdict(queue, pkt, get_next_mark(pkt, false), NULL);
        goto end;
    }

    const __auto_type tcp_payload_len = nfq_tcp_get_payload_len(tcp_hdr, pkt_buff);
    if (tcp_payload_len < USER_AGENT_MATCH_LENGTH) {
        send_verdict(queue, pkt, get_next_mark(pkt, false), NULL);
        goto end;
    }

    count_tcp_packet();

    // cannot find User-Agent: in this packet
    if (tcp_payload_len - 2 < USER_AGENT_MATCH_LENGTH) {
        send_verdict(queue, pkt, get_next_mark(pkt, false), NULL);
        goto end;
    }

    // FIXME: can lead to false positive,
    //        should also get CTA_COUNTERS_ORIG to check if this packet is a initial tcp packet

    //    if (!is_http_protocol(tcp_payload, tcp_payload_len)) {
    //        send_verdict(queue, pkt, get_next_mark(pkt, false), NULL);
    //        goto end;
    //    }
    count_http_packet();

    const void *search_start = tcp_payload;
    unsigned int search_length = tcp_payload_len;
    bool has_ua = false;

    while (true) {
        // minimal length of User-Agent: is 12
        if (search_length - 2 < USER_AGENT_MATCH_LENGTH) {
            break;
        }

        char *ua_pos = memncasemem(search_start, search_length, USER_AGENT_MATCH, USER_AGENT_MATCH_LENGTH);
        if (ua_pos == NULL) {
            break;
        }

        has_ua = true;

        void *ua_start = ua_pos + USER_AGENT_MATCH_LENGTH;

        // for non-standard user-agent like User-Agent:XXX with no space after colon
        if (*(char *)ua_start == ' ') {
            ua_start++;
        }

        const void *ua_end = memchr(ua_start, '\r', tcp_payload_len - (ua_start - tcp_payload));
        if (ua_end == NULL) {
            syslog(LOG_INFO, "User-Agent header is not terminated with \\r, not mangled.");
            send_verdict(queue, pkt, get_next_mark(pkt, true), NULL);
            goto end;
        }
        const unsigned int ua_len = ua_end - ua_start;
        const unsigned long ua_offset = ua_start - tcp_payload;

        if (type == IPV4) {
            if (!nfq_tcp_mangle_ipv4(pkt_buff, ua_offset, ua_len, replacement_user_agent_string, ua_len)) {
                syslog(LOG_ERR, "Failed to mangle ipv4 packet");
                goto end;
            }
        } else {
            if (!nfq_tcp_mangle_ipv6(pkt_buff, ua_offset, ua_len, replacement_user_agent_string, ua_len)) {
                syslog(LOG_ERR, "Failed to mangle ipv6 packet");
                goto end;
            }
        }

        search_length = tcp_payload_len - (ua_end - tcp_payload);
        search_start = ua_end;
    }

    if (has_ua) {
        count_user_agent_packet();
    }

    send_verdict(queue, pkt, get_next_mark(pkt, has_ua), pkt_buff);

end:
    free(pkt->payload);
    if (pkt_buff != NULL) {
        pktb_free(pkt_buff);
    }

    try_print_statistics();
}

#undef MAX_USER_AGENT_LENGTH
#undef USER_AGENT_MATCH_LENGTH

#undef CONNMARK_ESTIMATE_LOWER
#undef CONNMARK_ESTIMATE_UPPER
#undef CONNMARK_ESTIMATE_VERDICT

#undef CONNMARK_NOT_HTTP
#undef CONNMARK_HTTP
