%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "config/", "test/", "mix.exs"],
        excluded: []
      },
      strict: true,
      color: true
    }
  ]
}
