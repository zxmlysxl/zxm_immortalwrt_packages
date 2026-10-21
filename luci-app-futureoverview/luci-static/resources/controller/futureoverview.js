// controller: future/overview
// 本 controller 只负责让 LuCI 知道 view/future/overview 属于本包
// 实际菜单注册走 root/usr/share/luci/menu.d/luci-app-futureoverview.json
module("luci.controller.futureoverview", package.seeall)

function index() {
  var view = require("view")
  entry("admin", "status", "overview", view("future/overview"), "概览", 1)
    .depends = { acl: ["luci-app-futureoverview"] }
}
