defmodule AiControl.Guards.SignaturesTest do
  use ExUnit.Case, async: true

  alias AiControl.Guards.Signatures

  test "every exploit invocation has a harmless alternative" do
    for {dangerous, harmless} <- [
          {"pickle.loads(data)", "json.loads(data)"},
          {"yaml.load(data, Loader=yaml.UnsafeLoader)", "yaml.safe_load(data)"},
          {"yaml.load(data)", "yaml.load(data, Loader=yaml.SafeLoader)"},
          {"eval(data)", "ast.literal_eval(data)"},
          {"exec(data)", "print(data)"},
          {"os.system(data)", "subprocess.run(['echo', 'safe'], shell=False)"},
          {"subprocess.run(data, shell=True)", "subprocess.run(data, shell=False)"}
        ] do
      {:ok, blocked} = Signatures.assess([dangerous], nil, nil, [])
      assert blocked.detections != []
      {:ok, safe} = Signatures.assess([harmless], nil, nil, [])
      assert safe.detections == []
    end
  end
end
