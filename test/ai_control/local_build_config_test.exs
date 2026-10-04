defmodule AiControl.LocalBuildConfigTest do
  use ExUnit.Case, async: false

  setup do
    previous = System.get_env("LOCAL_DOCKER")

    on_exit(fn ->
      if previous,
        do: System.put_env("LOCAL_DOCKER", previous),
        else: System.delete_env("LOCAL_DOCKER")
    end)
  end

  test "default production image requires secure cookies and has no development routes" do
    System.delete_env("LOCAL_DOCKER")
    config = Config.Reader.read!("config/prod.exs", env: :prod)

    assert config[:ai_control][:secure_cookies]
    refute config[:ai_control][:local_docker]
    refute config[:ai_control][:dev_routes]
    assert is_list(config[:ai_control][AiControlWeb.Endpoint][:force_ssl])
    refute config[:swoosh][:local]
  end

  test "explicit local build enables HTTP sessions and organizer mailbox routes" do
    System.put_env("LOCAL_DOCKER", "1")
    config = Config.Reader.read!("config/prod.exs", env: :prod)

    refute config[:ai_control][:secure_cookies]
    assert config[:ai_control][:local_docker]
    assert config[:ai_control][:dev_routes]
    refute config[:ai_control][AiControlWeb.Endpoint][:force_ssl]
    assert config[:swoosh][:local]
  end
end
