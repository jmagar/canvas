defmodule Canvas.CodexTest do
  use ExUnit.Case, async: false
  alias Canvas.{Store, Agents}
  alias Canvas.Codex.Session

  setup do
    old = Application.get_env(:canvas, :codex_binary)
    Application.put_env(:canvas, :codex_binary, Path.expand("test/fixtures/app_server.py"))
    on_exit(fn -> Application.put_env(:canvas, :codex_binary, old) end)
    :ok
  end

  test "handshake, request correlation and streamed terminal state persist after UI disconnect" do
    Store.subscribe()
    node = Store.create(%{"title" => "Protocol test"})
    assert :ok = Agents.chat(node["id"], "Test")
    assert_completed(node["id"])
    actual = Store.get(node["id"])
    assert actual["thread_id"] == "fixture-thread"
    assert actual["turn_id"] == nil
    assert Enum.any?(actual["messages"], &(&1["text"] == "Fixture answer"))

    assert {:ok, %{"thread" => %{"id" => "fixture-thread"}}} =
             Session.request(node["id"], "thread/resume", %{"threadId" => actual["thread_id"]})

    [{pid, _}] = Registry.lookup(Canvas.Codex.Registry, node["id"])
    DynamicSupervisor.terminate_child(Canvas.Codex.Supervisor, pid)
  end

  defp assert_completed(id, attempts \\ 50)
  defp assert_completed(_, 0), do: flunk("No terminal event from protocol fixture")

  defp assert_completed(id, attempts) do
    if Store.get(id)["status"] == "completed" do
      :ok
    else
      assert_receive :board_changed, 3000
      assert_completed(id, attempts - 1)
    end
  end
end
