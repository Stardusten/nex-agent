# 用 Elixir 养 Agent 30 天，我后悔没早点开始

> 我是一个写了 8 年 Python 的开发者。30 天前，我为了养 Agent，学了 Elixir。现在我想说：真香。

---

## 第 0 天：为什么又是新语言

事情是这样的。

我决定写 NexAgent 的时候，面临一个选择：用什么语言？

**选项 A：Python**
- 优势：AI 生态最好，LangChain、AutoGPT 都是 Python
- 劣势：GIL、asyncio 复杂、长期运行容易内存泄漏

**选项 B：Node.js/TypeScript**
- 优势：OpenClaw 在用，事件驱动适合 IO 密集型
- 劣势：单进程、Callback Hell、长期运行稳定性差

**选项 C：Go**
- 优势：并发好、编译快、部署简单
- 劣势：缺乏 Actor 模型、热更新困难

**选项 D：Elixir**
- 优势：OTP、监督树、热更新、7×24 小时运行基因
- 劣势：小众、生态弱、招人难

我纠结了三天。

最后选择 Elixir，不是因为 Elixir 语法优雅（虽然确实优雅），而是因为 **OTP 的「永不停止」哲学，和 Agent 的长期陪伴属性完美契合**。

但我心里没底。写了 8 年 Python，我对函数式编程一窍不通。

---

## 第 1-3 天：语法暴击

打开 Elixir 教程，第一行代码：

```elixir
defmodule Hello do
  def world do
    IO.puts "Hello, World!"
  end
end
```

我心想：这不就是 Python 的 class 吗？小意思。

然后看到了这个：

```elixir
# 管道操作符
data
|> transform_a()
|> transform_b()
|> transform_c()
```

嗯，挺优雅的，比 `transform_c(transform_b(transform_a(data)))` 好读。

再然后：

```elixir
# 模式匹配
%{status: 200, body: body} = HTTPoison.get!(url)
```

我：？？？

这是啥？解构赋值？还能自动匹配？如果 status 不是 200 会咋样？

看了文档：会抛出 MatchError。

我陷入了沉思。这和我熟悉的 Python 完全不同。

**第 3 天晚上**，我对着屏幕骂了一句：「这什么反人类语法！」

---

## 第 4-7 天：监督树顿悟

但第 4 天，我看到了 OTP 的监督树。

```elixir
defmodule NexAgent.Application do
  use Application

  def start(_type, _args) do
    children = [
      NexAgent.InfrastructureSupervisor,
      NexAgent.WorkerSupervisor,
      NexAgent.Gateway
    ]

    Supervisor.start_link(children, strategy: :rest_for_one)
  end
end
```

`strategy: :rest_for_one` 的意思是：如果基础设施崩溃，所有 Worker 联动重启；如果只是某个 Worker 失败，只重启那个 Worker。

我突然想起了用 Python 写 Agent 时的痛苦：

```python
# Python 版本
try:
    result = tool.execute()
except Exception as e:
    logger.error(f"Tool failed: {e}")
    # 然后呢？重启整个服务？还是让 Agent 继续带着 bug 运行？
```

而在 Elixir：

```elixir
# 每个工具调用都是独立进程
Task.Supervisor.start_child(NexAgent.ToolTaskSupervisor, fn ->
  tool_module.execute(args)
end)

# 如果崩溃，监督树自动重启这个任务，主 Agent 不受影响
```

**第 7 天晚上**，我在笔记本上写下：**「这不是语法糖，是架构哲学。」**

---

## 第 8-15 天：从 Pythonic 到 Elixir-way

第 8 天，我开始迁移核心逻辑。

Python 版本（伪代码）：

```python
class Agent:
    def __init__(self):
        self.memory = []
        self.tools = {}
    
    async def run(self, message):
        # 1. 构建上下文
        context = self.build_context()
        
        # 2. 调用 LLM
        response = await llm.chat(context + [message])
        
        # 3. 执行工具
        if response.tool_calls:
            for tool_call in response.tool_calls:
                try:
                    result = await self.tools[tool_call.name](tool_call.args)
                    self.memory.append(result)
                except Exception as e:
                    logger.error(e)
                    # 怎么处理错误？重试？跳过？终止？
        
        return response
```

问题：
1. 一个工具失败，整个流程卡住
2. 内存泄漏难以追踪
3. 热更新需要重启服务

Elixir 版本：

```elixir
defmodule NexAgent.Runner do
  use GenServer

  def handle_cast({:run, message}, state) do
    # 1. 构建上下文（异步，不阻塞）
    context = ContextBuilder.build(state.session_id)
    
    # 2. 调用 LLM
    {:ok, response} = LLM.chat(context ++ [message])
    
    # 3. 并发执行工具，每个工具是独立进程
    results = 
      response.tool_calls
      |> Enum.map(&spawn_tool_execution/1)
      |> Task.yield_many(30_000)  # 30秒超时
    
    # 4. 处理结果（成功的收集，失败的重试或记录）
    new_state = process_results(results, state)
    
    {:noreply, new_state}
  end
  
  defp spawn_tool_execution(tool_call) do
    Task.Supervisor.async_nolink(NexAgent.ToolTaskSupervisor, fn ->
      Tool.Registry.execute(tool_call.name, tool_call.args)
    end)
  end
end
```

区别：
- 每个工具调用都是独立进程（崩溃隔离）
- 并发执行，30秒超时（资源控制）
- 失败的任务可以单独重试，不影响其他任务

**第 15 天**，我写完了核心 Agent 循环。代码量比 Python 版本少了 40%，但并发能力和稳定性提升了不止一个量级。

---

## 第 16-22 天：热更新的震撼

第 16 天，我遇到了一个 bug。

Agent 的邮件发送功能有个边界条件处理错了，导致某些邮件会重复发送。

在 Python 时代，我的修复流程是：
1. 改代码
2. 本地测试
3. 提交 Git
4. CI/CD
5. 凌晨 2 点上线（低峰期）
6. 重启服务
7. 验证
8. 回滚预案（万一失败）

整个过程需要 2 小时，还要担心重启期间的服务中断。

在 Elixir，我写了这段代码：

```elixir
defmodule NexAgent.CodeUpgrade do
  def upgrade(module, new_code) do
    with :ok <- validate(new_code),
         :ok <- backup(module),
         :ok <- write_source(module, new_code),
         {:ok, _} <- compile(module),
         :ok <- hot_reload(module),
         :ok <- health_check(module) do
      {:ok, :upgraded}
    else
      {:error, reason} ->
        rollback(module)
        {:error, reason}
    end
  end
  
  defp hot_reload(module) do
    # OTP 的 code_change 回调
    :code.purge(module)
    :code.load_file(module)
    :ok
  end
end
```

然后我在 Telegram 里对 Agent 说：「修复邮件重复发送的 bug」。

Agent 自己：
1. 查看了邮件发送模块的源码
2. 发现了边界条件问题
3. 生成了修复代码
4. 调用 `CodeUpgrade.upgrade`
5. 热加载成功
6. 健康检查通过

**整个过程 4 分钟。服务没有重启，用户没有感知。**

我坐在椅子上，有点恍惚。

这就是 OTP 的力量。**「永不停止」不是口号，是原语。**

---

## 第 23-30 天：真香时刻

第 23 天，我统计了一下数据：

**NexAgent 运行 30 天：**
- Uptime：99.8%（只有计划内的代码升级重启）
- 内存占用：稳定在 200MB（没有泄漏）
- 处理消息：约 5000 条
- 自我升级：3 次（Agent 自己发现并修复了 2 个 bug）

对比我之前用 Python 写的类似服务：
- 每周需要重启一次（内存泄漏）
- 高峰期容易卡住（GIL 瓶颈）
- 发版需要凌晨 2 点起床

**第 30 天**，我在 Twitter 上发了一条动态：

> "用 Elixir 写 Agent 30 天，我后悔没早点开始。不是 Elixir 语法多好，是 OTP 的「永不停止」哲学，完美契合 Agent 的长期陪伴属性。"

有人评论：「但 Elixir 生态弱啊，招人难啊。」

我回复：「对于需要 7×24 小时运行的系统，架构正确比生态丰富更重要。而且，Agent 本身可以弥补生态差距——让它自己写工具就好了。」

---

## 给 Python/JS 开发者的建议

如果你也在考虑写长期运行的 Agent，我的建议是：

**短期项目（< 6 个月）**：用你熟悉的语言，Python/Node/Go 都可以。

**长期项目（> 6 个月，需要 7×24 小时）**：认真考虑 Elixir/OTP。

学习曲线？确实有点陡。模式匹配、函数式编程、Actor 模型，都需要适应。

但一旦你理解了 OTP 的「监督树」、「进程隔离」、「热更新」，你会发现：

**这些不是语法糖，是构建「永不停止系统」的原语。**

而 Agent，恰恰需要「永不停止」。

---

## 写在最后

8 年 Python 开发者，30 天 Elixir 新手。

我现在不会说「Elixir 比 Python 好」。

但我会说：**「对于 Agent 这个场景，Elixir/OTP 是更正确的选择。」**

就像你不会用 Python 写操作系统，不会用 C 写 Web 后端——

**不同的场景，需要不同的工具。**

Agent 需要长期运行、自我进化、永不崩溃。

OTP 为此而生。

**后悔没早点开始？

不，后悔的是，没早点理解「永不停止」的重要性。**

---

**相关链接**：
- NexAgent GitHub: https://github.com/gofenix/nex-agent
- Elixir 官方教程: https://elixir-lang.org/getting-started/introduction.html
- 系列文章：
  - 《养了 OpenClaw 之后，我开始种自己的树》
  - 《我的 Agent 在凌晨三点给自己做了个手术》
  - 《我的 Agent 开始质疑我的代码了》

---

--- 
**系列文章**（建议按顺序阅读）：
1. 🌱 [养了 OpenClaw 之后，我开始种自己的树](01-openclaw-vs-nexagent.md)
2. 🔧 [我的 Agent 在凌晨三点给自己做了个手术](02-agent-self-surgery.md)
3. 💬 [我的 Agent 开始质疑我的代码了](03-agent-challenges-me.md)
4. 🚀 [用 Elixir 养 Agent 30 天，我后悔没早点开始](04-elixir-30-days.md)（本文）
5. 🤔 [别急着部署，先想想你想养什么样的 Agent](05-raising-vs-using.md)
6. 📊 [30 天养 Agent 实录：数据、故事与思考](06-30-days-report.md)

---

*最后更新：2026-03-13*
