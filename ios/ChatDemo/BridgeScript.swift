//
//  BridgeScript.swift
//  ChatDemo
//
//  注入到页面里的原生桥。前端源码保持零改动，原生在页面层接管三个浏览器里
//  有、WKWebView 里没有（或行为不对）的能力：
//    1. <a download>：WKWebView 忽略 download 属性，不会落盘，转成原生分享面板；
//    2. 新标签预览（blob:/data:，含图片与 PDF）：转成原生 QuickLook；
//    3. 长按图片的系统菜单「存储图像」同样走第 1 条的通道。
//
//  两个入口都要挂：真实用户点击走 DOM 事件，代码里 createElement + click()
//  创建的游离节点不会冒泡到 document，只能从原型上拦。
//

enum BridgeScript {
    /// 原生消息处理器名字，与 WebViewController 注册时保持一致。
    static let handlerName = "chatDemo"

    static let source = #"""
(function () {
  if (window.__chatDemoBridgeInstalled) { return }
  window.__chatDemoBridgeInstalled = true

  var handlers = window.webkit && window.webkit.messageHandlers
  var bridge = handlers && handlers.chatDemo
  if (!bridge) { return }

  function post(payload) {
    try { bridge.postMessage(payload) } catch (error) { /* 页面已销毁 */ }
  }

  function toBase64(blob) {
    return blob.arrayBuffer().then(function (buffer) {
      var bytes = new Uint8Array(buffer)
      var parts = []
      var chunk = 0x8000
      for (var index = 0; index < bytes.length; index += chunk) {
        parts.push(String.fromCharCode.apply(null, bytes.subarray(index, index + chunk)))
      }
      return btoa(parts.join(''))
    })
  }

  function sendBlob(action, name, blob) {
    return toBase64(blob).then(function (data) {
      post({
        action: action,
        name: name || 'file',
        mime: blob.type || 'application/octet-stream',
        data: data
      })
    })
  }

  function fetchAndSend(action, href, name) {
    fetch(href)
      .then(function (response) { return response.blob() })
      .then(function (blob) { return sendBlob(action, name, blob) })
      .catch(function (error) { post({ action: 'failed', message: String(error) }) })
  }

  function isInlineUrl(href) {
    return href.indexOf('blob:') === 0 || href.indexOf('data:') === 0
  }

  /** 返回 true 表示已由原生接管，调用方不要再执行默认行为。 */
  function handleAnchor(anchor, fallbackName) {
    if (!anchor) { return false }
    var href = anchor.getAttribute('href')
    if (!href) { return false }
    var download = anchor.getAttribute('download')
    if (download !== null) {
      fetchAndSend('saveFile', href, download || fallbackName || 'file')
      return true
    }
    if (anchor.getAttribute('target') === '_blank' && isInlineUrl(href)) {
      var name = anchor.getAttribute('title') || fallbackName || 'preview'
      fetchAndSend('previewFile', href, name)
      return true
    }
    return false
  }

  function closestAnchor(node) {
    while (node && node.nodeType !== 1) { node = node.parentNode }
    return node && node.closest ? node.closest('a[href]') : null
  }

  // 入口一：真实用户点击（含 React 渲染进文档的 <a>）。
  document.addEventListener('click', function (event) {
    if (handleAnchor(closestAnchor(event.target), null)) {
      event.preventDefault()
      event.stopPropagation()
    }
  }, true)

  // 入口二：代码里 createElement('a').click() 的游离节点。
  var nativeClick = HTMLAnchorElement.prototype.click
  HTMLAnchorElement.prototype.click = function () {
    if (handleAnchor(this, null)) { return }
    return nativeClick.apply(this, arguments)
  }

  // 入口三：window.open 打开内联地址（外部 http 链接仍交给原生开浏览器）。
  var nativeOpen = window.open
  window.open = function (url, target, features) {
    if (typeof url === 'string' && isInlineUrl(url)) {
      fetchAndSend('previewFile', url, 'preview')
      return null
    }
    return nativeOpen.apply(window, arguments)
  }

  // 长按图片的「存储图像」在 WKWebView 里会失效，补一个保存入口。
  document.addEventListener('contextmenu', function (event) {
    var target = event.target
    if (!target || target.tagName !== 'IMG') { return }
    var source = target.currentSrc || target.src || ''
    if (!isInlineUrl(source)) { return }
    event.preventDefault()
    fetchAndSend('saveFile', source, 'image')
  }, true)
})();
"""#
}