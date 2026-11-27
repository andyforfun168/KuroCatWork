## v1.4.7 · macOS task visibility fix / macOS 任务显示修复

- 修复退出再进入工作模式后，仍在运行的同一任务被“已查看”标记隐藏的问题；已受影响的本地记录也会在下一次任务检测时恢复。
- 已完成任务仍按原规则淡出清理，不会因修复而重新弹出。
- 中英文 README 顶部改为三段正方形工作模式动画：自主打字、等待处理、拎起拖动。桌面横排，窄屏换行。
- 保留当前四款皮肤、美术和动作。

macOS 下载 `KuroCatWork-macOS-universal.zip`，退出旧版后替换 App，再进入工作模式。沿用现有设置；任务检查约每 6 秒一次。

本次应用修复针对 macOS。Windows / Linux 安装包与 v1.4.6 完全相同，随本次 Release 一并提供，便于按平台下载。

This release fixes macOS running tasks staying hidden after leaving and re-entering work mode. Already affected local records are revived on the next successful task scan, while cleared completed tasks stay cleared. The accepted cat artwork and animation are unchanged. Windows / Linux packages are unchanged from v1.4.6.
