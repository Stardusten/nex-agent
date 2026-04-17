# NexAgent Agent Quick Spec

改代码前先按这份速查表对齐，细则见 `docs/spec.md`。

## 1. 先判断你在改哪一层

- `SOUL`：人格、价值观、风格
- `USER`：用户画像、偏好、协作方式
- `MEMORY`：长期事实
- `SKILL`：可复用工作流
- `TOOL`：确定性能力
- `CODE`：框架内部实现

不要跨层乱写。`TOOLS.md` 不是工具真相源；workspace custom tool 也不是 framework code layer。

## 2. 先找真相源，不要复制状态

- 配置、prompt、tool definitions、skills 可见性不要各处自己读一份
- 长期进程 state 只放必要状态，不要顺手缓存整套 runtime world view
- 涉及 workspace 路径时优先复用 `Nex.Agent.Workspace`
- 能靠统一入口读到的数据，不要再新增一套平行读取逻辑

## 3. 改动要符合当前架构

- 这是长期运行的 OTP agent，不是一次性脚本
- `Gateway` / channel / worker / registry / session / memory 都是系统边界，不要随便串层
- channel 特有协议留在 channel 模块里消化，不要把 Feishu/Telegram 细节散到通用层
- provider 差异收敛在 `llm/provider_profile.ex` 和 `llm/req_llm.ex`

## 4. 写代码的方式

- 公共接口写清 `@spec`，复杂模块写清职责边界
- 函数过长就拆 helper，避免一个函数同时做解析、分支、IO、状态回写、广播
- 错误返回要可操作，失败语义要明确
- 写日志记录关键状态和耗时，不打印敏感明文
- 延续当前代码风格，不要引入另一套完全不同的写法体系

## 5. 最容易踩坑的几个点

- 不要把 `Config.load/0` 式的分散读取再复制到新模块
- 不要把 skill 做成隐藏代码执行器；代码能力应该做成 tool
- 不要只看 `definitions(:all)`；新增 tool 要考虑 `:subagent` / `:cron` surface
- 不要让写文件后的失败把仓库留在半坏状态；需要回滚就回滚
- 不要为了省事把临时实现写成长期 contract

## 6. 测试和文档

- 先补 contract 测试，再补实现细节测试
- 用临时 workspace / 临时 config 做隔离测试，不依赖本机现有状态
- 改了冻结边界、主线架构或执行方式，记得同步 `docs/dev/*`
- 执行计划写到 `docs/dev/task-plan/` 时，必须按 Stage 模板写，不要写成长篇设计文

## 7. 动手前最后自检

1. 我改的是哪一层？
2. 真相源在哪里？
3. 这次改动会不会新增重复状态或破坏一致性？
4. 失败时怎么回滚、保持旧值或重建？
5. 最窄的有效验证是什么？
