defmodule Canvas.StoreTest do
  use ExUnit.Case, async: false
  alias Canvas.Store

  test "atomic snapshot persists and restart marks stale running agents interrupted" do
    path = Path.join(System.tmp_dir!(), "canvas-store-#{Store.id()}.json")
    name = :canvas_persistence_test
    start_supervised!({Store, path: path, name: name})

    Store.mutate(
      fn state ->
        {nil,
         %{
           state
           | nodes: [
               %{
                 "id" => "persisted",
                 "status" => "running",
                 "turn_id" => "old",
                 "messages" => [%{"text" => "retained"}]
               }
             ],
             edges: []
         }}
      end,
      name
    )

    assert File.exists?(path)
    stop_supervised(Store)
    start_supervised!({Store, path: path, name: name})
    [node] = Store.snapshot(name).nodes
    assert node["status"] == "interrupted"
    assert node["turn_id"] == nil
    assert node["messages"] == [%{"text" => "retained"}]
    File.rm!(path)
  end

  test "context includes only selected project and its parent" do
    a = Store.create(%{"title" => "First", "description" => "UNIQUE_PRIVATE_A"})
    b = Store.create(%{"title" => "Second", "description" => "UNIQUE_PRIVATE_B"})
    [%{"text" => text}] = Canvas.Context.input(a, "Help")
    assert text =~ "UNIQUE_PRIVATE_A"
    refute text =~ "UNIQUE_PRIVATE_B"

    child =
      Store.create(%{
        "kind" => "agent",
        "parent_id" => b["id"],
        "title" => "Child",
        "description" => "CHILD"
      })

    [%{"text" => text}] = Canvas.Context.input(child, "Help")
    assert text =~ "UNIQUE_PRIVATE_B"
    assert text =~ "CHILD"
    refute text =~ "UNIQUE_PRIVATE_A"
  end

  test "classification rejects unsupported taxonomy and out-of-range confidence" do
    decision = %{
      "engine" => "clef",
      "labels" => ["decision"],
      "confidence" => 0.9,
      "rationale" => "Explicit decision statement"
    }

    assert {:ok, _} = Canvas.Classifier.validate(decision)
    assert {:error, _} = Canvas.Classifier.validate(%{decision | "confidence" => 2})
    assert {:error, _} = Canvas.Classifier.validate(%{decision | "labels" => ["invented"]})
    assert {:error, :decision_model_not_configured} = Canvas.Classifier.classify("welcome")
  end
end
