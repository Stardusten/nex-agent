%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "web/", "apps/", "config/", "mix.exs"],
        excluded: [~r"/test/support/", ~r"/deps/", ~r"/_build/"]
      },
      strict: true,
      color: true,
      checks: [
        {Credo.Check.Design.AliasUsage,
         [priority: :low, if_nested_deeper_than: 100, if_called_more_often_than: 0]},
        {Credo.Check.Readability.ModuleDoc, []},
        {Credo.Check.Refactor.CondStatements, []},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 25]},
        {Credo.Check.Refactor.FunctionArity, [max_arity: 10]},
        {Credo.Check.Refactor.NegatedConditionsWithElse, []},
        {Credo.Check.Refactor.Nesting, [max_nesting: 5]},
        {Credo.Check.Refactor.UnlessWithElse, []}
      ]
    }
  ]
}
