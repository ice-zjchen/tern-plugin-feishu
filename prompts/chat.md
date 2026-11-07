<!-- @turn -->
任务类型：工作台用户直接对话。用户可能在追问，也可能要改判断、改回复稿或改任务说明。
用户对这条消息说：{{said}}

当前判断：{{decision}}
当前回复稿：{{draft}}
当前任务说明：{{task}}
当前执行 Workspace（JSON 字符串，空字符串为默认目录）：{{workspace}}
{{context}}

{{format}}

<!-- @context -->
上下文：
{{context}}

<!-- @none -->
（暂无）

<!-- @format -->
只输出一个 JSON 对象，不要 markdown 代码块，不要其他文字：
{"reply":"你对用户说的话","decision":"用户要改判时填 ignore|reply|deep，否则空字符串","draft":"用户要改回复或改判为回复时，这里是完整回复正文，否则空字符串","task":"用户要改任务或改判为深入时，这里是完整业务任务说明，否则空字符串","risk":"task 涉及难以撤销或影响他人的动作时，用 12 字以内写明这个动作，否则空字符串"}
这里同样不执行操作：用户要动手做的事，改判为 deep 并写进 task。
要修改执行目录时额外返回 workspace 字段：绝对路径表示指定目录，空字符串表示回到默认目录。不修改时省略 workspace；可只修改 workspace 而不重写 task。目录必须遵守当前 Workspace 的可信目录规则。task 中不要生成路由 Markdown。
