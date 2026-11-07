# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
# shellcheck shell=bash
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 装之前要准备（如先配出口代理）：写 before_install。

web_assert() { grep -q '你好'; }   # 示例页的标题

identity_check() { # 页面回显的就是网关注入的用户名
  local page
  page="$(dweb /)" || { echo "页面失败：$page"; return 1; }
  grep -qF "你好，$SMOKE_OWNER" <<<"$page" || { echo "页面没回显用户 $SMOKE_OWNER：$(head -c 120 <<<"$page")"; return 1; }
}

# 数据：Ollama 的用户数据就是模型（/root/.ollama，升级重装都保留）。data_write 先拉上游官方库里
# 最小的主流模型 all-minilm:22m（约 46 MB）做底，再 ollama cp 出一个带随机标记的引用；拉模型要出网
# （registry.ollama.ai），环境没配出网时这里如实失败。
# 容器按核心打的标签找，不拼名字：钩子契约里没有 slug，data_write 又跑在主流程导出实例名之前。
_ollama_container() {
  local inst="${SMOKE_INSTANCE:-}" args=(--filter label=wonton.plugin=com.ollama.ollama --filter label=wonton.service=ollama)
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
  docker ps --format '{{.Names}}' "${args[@]}" | head -1
}

data_write() {
  local marker container base
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  container="$(_ollama_container)"
  [[ -n "$container" ]] || { echo "找不到 ollama 容器（wonton.instance 标签）"; return 1; }
  base="all-minilm:22m"
  docker exec "$container" ollama pull "$base" >/dev/null ||
    { echo "拉 $base 失败（容器 $container 出网不可用？）"; return 1; }
  docker exec "$container" ollama cp "$base" "$marker" ||
    { echo "ollama cp 成 $marker 失败"; return 1; }
  printf '%s' "$marker" >"$SMOKE_STATE"
}

data_check() {
  local marker container listing
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  marker="$(cat "$SMOKE_STATE")" || { echo "读不到 $SMOKE_STATE"; return 1; }
  container="$(_ollama_container)"
  [[ -n "$container" ]] || { echo "找不到 ollama 容器（wonton.instance 标签）"; return 1; }
  listing="$(docker exec "$container" ollama ls)" || { echo "ollama ls 失败"; return 1; }
  awk -v m="$marker" '$1 == m { found = 1 } END { exit !found }' <<<"$listing" ||
    { echo "模型标记不在了：找了 $marker，ollama ls 现在是：$(head -c 200 <<<"$listing")"; return 1; }
}
