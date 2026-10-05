defmodule Canvas.Classifier do
  @moduledoc "Decision-model boundary for Jev / clef. Keeps classifications separate from source facts."
  alias Canvas.Store

  @types ~w(requirement decision code evidence conversation document image link issue task pr other)
  def pending do
    %{
      "status" => "pending",
      "engine" => "jev/clef",
      "labels" => [],
      "reason" => "Decision model not configured"
    }
  end

  def adapter do
    module = Application.get_env(:canvas, :classifier, Canvas.DecisionModels.SystemOne)

    if module == Canvas.DecisionModels.SystemOne and not module.configured?(),
      do: nil,
      else: module
  end

  def classify(node_id) do
    case adapter() do
      nil ->
        {:error, :decision_model_not_configured}

      module ->
        node = Store.get(node_id)

        Task.Supervisor.start_child(Canvas.Tasks, fn ->
          project_source = %{
            "id" => "project",
            "kind" => "project",
            "name" => node["title"],
            "description" => node["description"],
            "messages" => Enum.take(node["messages"], -10)
          }

          Enum.each([project_source | Enum.take(node["attachments"], 30)], fn source ->
            result =
              try do
                module.classify(source, Map.take(node, ~w(id title description)))
              rescue
                e -> {:error, Exception.message(e)}
              end

            classification =
              case result do
                {:ok, decision} ->
                  case validate(decision) do
                    {:ok, valid} ->
                      Map.merge(valid, %{
                        "status" => "classified",
                        "classified_at" => DateTime.to_iso8601(DateTime.utc_now()),
                        "source_sha256" => source["sha256"]
                      })

                    {:error, why} ->
                      Map.merge(pending(), %{"status" => "failed", "reason" => why})
                  end

                {:error, why} ->
                  Map.merge(pending(), %{"status" => "failed", "reason" => inspect(why)})
              end

            Store.change(node_id, fn n ->
              if source["id"] == "project" do
                Map.put(n, "classification", classification)
              else
                Map.update!(n, "attachments", fn attachments ->
                  Enum.map(attachments, fn a ->
                    if a["id"] == source["id"],
                      do: Map.put(a, "classification", classification),
                      else: a
                  end)
                end)
              end
            end)
          end)
        end)

        :ok
    end
  end

  def validate(
        %{
          "engine" => engine,
          "labels" => labels,
          "confidence" => confidence,
          "rationale" => rationale
        } = decision
      )
      when is_binary(engine) and is_list(labels) and is_number(confidence) and
             is_binary(rationale) do
    if confidence >= 0 and confidence <= 1 and length(labels) <= 12 and
         Enum.all?(labels, &(&1 in @types)) do
      {:ok,
       Map.take(
         decision,
         ~w(engine model_version labels confidence rationale probabilities answers usage taxonomy_version review_required)
       )}
    else
      {:error, "Invalid classification labels or confidence"}
    end
  end

  def validate(_), do: {:error, "Decision must include engine, labels, confidence and rationale"}
end
