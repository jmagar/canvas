defmodule Canvas.DecisionModel do
  @moduledoc "Implement this boundary with the confirmed Jev / clef API. No guessed external endpoints."
  @callback classify(source :: map(), project :: map()) :: {:ok, map()} | {:error, term()}
end
