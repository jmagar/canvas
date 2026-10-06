defmodule Canvas.IngestionTest do
  use ExUnit.Case, async: false
  alias Canvas.{Store, Ingestion}

  test "a new source gets durable stages and an honest reference scaffold when integrations are unavailable" do
    Store.subscribe()
    node = Store.create(%{"title" => "Ingestion test", "description" => "Explain the source"})

    Store.attach(node["id"], %{
      "id" => "ingest-fixture",
      "name" => "Reference",
      "kind" => "link",
      "url" => "https://example.com/spec"
    })

    await_scaffold(node["id"])
    source = hd(Store.get(node["id"])["attachments"])
    assert source["ingestion"]["status"] == "local"
    assert source["ingestion"]["reason"] =~ "does not require embeddings"
    path = Store.get(node["id"])["reference_document"]["path"]
    text = File.read!(path)
    assert text =~ "https://example.com/spec"
    assert text =~ "Agent analysis pending"
    [%{"text" => context}] = Canvas.Context.input(Store.get(node["id"]), "Help")
    assert context =~ "Context reference document"
  end

  test "Axon queued or zero-vector results are never claimed embedded" do
    assert {:error, {:axon_not_terminal, _}} =
             Canvas.Integrations.Axon.normalize(%{"status" => "queued", "job_id" => "j1"})

    assert {:error, {:axon_no_vectors, _}} =
             Canvas.Integrations.Axon.normalize(%{
               "status" => "completed",
               "counts" => %{"vector_points_total" => 0}
             })

    assert {:ok, %{"receipt" => %{"job_id" => "j1"}, "text" => "Extracted"}} =
             Canvas.Integrations.Axon.normalize(%{
               "status" => "completed",
               "job_id" => "j1",
               "counts" => %{"vector_points_total" => 4},
               "inline" => %{"content" => %{"kind" => "inline_text", "text" => "Extracted"}}
             })
  end

  test "reference analysis rejects hallucinated relationships and accepts known source IDs" do
    node = Store.create(%{"title" => "Relationships"})

    Store.attach(node["id"], %{
      "id" => "known-id",
      "kind" => "link",
      "name" => "Spec",
      "url" => "https://example.com"
    })

    ref = %{
      "summary" => "Spec",
      "relevance" => "Defines the goal",
      "when_to_reference" => "Planning",
      "limitations" => "Incomplete",
      "related" => [%{"source_id" => "known-id", "reason" => "Same subject"}]
    }

    assert :ok = Ingestion.validate_reference(ref, Store.get(node["id"]))

    assert {:error, _} =
             Ingestion.validate_reference(
               %{ref | "related" => [%{"source_id" => "made-up", "reason" => "Unknown"}]},
               Store.get(node["id"])
             )

    assert {:error, _} = Ingestion.validate_reference(%{}, node)
  end

  test "Jev and CLEF preserve distributions and mark uncertain outputs for review" do
    body = %{
      "model" => "fixture-model",
      "answers" => %{
        "content_type" => %{
          "choice" => "decision",
          "confidence" => 0.4,
          "probabilities" => %{"decision" => 0.6, "document" => 0.4}
        }
      }
    }

    assert {:ok, result} = Canvas.DecisionModels.SystemOne.normalize(body, "clef")
    assert result["review_required"]
    assert result["probabilities"]["document"] == 0.4
    assert result["model_version"] == "fixture-model"
    bad = put_in(body, ["answers", "content_type", "probabilities"], %{"decision" => 3})

    assert {:error, :invalid_decision_response} =
             Canvas.DecisionModels.SystemOne.normalize(bad, "jev")
  end

  test "Depot incomplete discovery remains visible" do
    reply = %{
      "result" => %{
        "structuredContent" => %{
          "result" => %{
            "results" => [%{"name" => "example", "kind" => "skill"}],
            "incomplete" => true,
            "incompleteSources" => ["depot"]
          }
        }
      }
    }

    assert {:ok, result} = Canvas.Integrations.Depot.normalize(reply)
    assert result["incomplete"]
    assert result["incomplete_sources"] == ["depot"]
  end

  defp await_scaffold(id, attempts \\ 30)
  defp await_scaffold(_, 0), do: flunk("Ingestion did not reach reference scaffold")

  defp await_scaffold(id, attempts) do
    if Store.get(id)["reference_document"] do
      :ok
    else
      assert_receive :board_changed, 3000
      await_scaffold(id, attempts - 1)
    end
  end
end
