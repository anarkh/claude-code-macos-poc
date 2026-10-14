import Foundation

/// Explicit offline-only layout sample; never reads or writes the user's conversations.
func conversationLayoutFixtureStore() -> MemoryConversationStore {
    let original = """
    この画面では、会話の内容と実行状態を同じ一覧で確認できます。

    入力した中国語は選択した言語に翻訳され、その翻訳が会話に表示されます。モデルの回答は元の文章のまま残ります。

    - 左側で会話を切り替えます。
    - 下部の入力欄から新しいメッセージを送信します。
    - 回答の下にあるボタンで中国語訳を表示します。

    翻訳後も元の回答は保持され、完了状態は回答のすぐ下に表示されます。
    """
    let chinese = """
    这个界面可以在同一列表里查看对话内容和执行状态。

    输入的中文会转换为选定语言，并显示在对话中。模型的回复按原文保留。

    - 在左侧切换会话。
    - 从底部输入框发送新消息。
    - 点击回复下方的按钮查看中文译文。

    翻译后仍保留原始回复，完成状态紧跟在回复下方。
    """
    let record = ConversationRecord(title: "长回复布局检查", messages: [
        .init(role: .assistant, text: original, translation: chinese),
        .init(role: .activity, text: "回复完成")
    ])
    let traceRecord = requestDetailsLayoutFixture()
    return MemoryConversationStore(.init(selectedID: record.id, conversations: [record, traceRecord]))
}

/// Synthetic, explicit offline samples for inspecting request details without credentials or network access.
private func requestDetailsLayoutFixture() -> ConversationRecord {
    let runID = UUID()
    let body = #"""
    {"model" : "deepseek-flash",
      "messages": [{"role":"user","content":"# 标题\\n**字面文本** <tag> `code` 中文\\n[REDACTED]"}],
      "max_tokens":4096, "stream":true
    }
    """#
    let headers = ["content-type": "application/json", "content-length": String(body.utf8.count),
                   "anthropic-version": "2023-06-01", "x-app": "cli",
                   "user-agent": "claude-code/offline-layout-fixture",
                   "x-claude-code-session-id": UUID().uuidString]
    let proxy = ChatRequestTraceProxy(url: "http://127.0.0.1:7897")
    let traces: [ChatRequestTrace] = [
        .init(attemptID: "\(runID.uuidString):1", attempt: 1, phase: .response,
              wireModel: "deepseek-flash", headers: headers, proxy: proxy,
              body: body, bodyBytes: body.utf8.count, secretsRedacted: true,
              status: 429, durationMS: 172.4, outcome: "http"),
        .init(attemptID: "\(runID.uuidString):2", attempt: 2, phase: .error,
              wireModel: "deepseek-flash", headers: headers, proxy: proxy,
              body: body, bodyBytes: body.utf8.count, secretsRedacted: true,
              durationMS: 1050.2, outcome: "network_error", errorCode: "PROVIDER_NETWORK_ERROR"),
        .init(attemptID: "\(runID.uuidString):3", attempt: 3, phase: .response,
              wireModel: "deepseek-flash", headers: headers, proxy: proxy,
              body: body, bodyBytes: body.utf8.count, secretsRedacted: true,
              status: 200, durationMS: 2458.6, outcome: "http")
    ]
    return ConversationRecord(title: "请求详情离线检查", messages: [
        .init(role: .user, text: "Show the literal request body.", originalText: "查看原始请求正文。", runID: runID),
        .init(role: .assistant, text: "这是离线合成样本。可切换三次请求样本，检查 HTTP 429、网络失败和成功响应的显示。", runID: runID, requestTraces: traces),
        .init(role: .activity, text: "回复完成"),
        .init(role: .user, text: "旧消息样本：请求详情应禁用并明确未记录。")
    ])
}
