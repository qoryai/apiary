defmodule Apiary.Stages.QuestionsUnreadable do
  # Raised when the stage runner reads a run of Explore's end and the newest questions of
  # its work item cannot be read (`Apiary.Explore.Questions.current/1`). An exit, a
  # refusal or a lost run rolls back, and the lost-run check tries it again
  # (`Apiary.Dispatches.RunEnd.lose/3`); a settle rolls back, and the settle sweep tries it
  # again. A claim, a failed harness walk and a held run store the end, and the stage
  # sweep acts on it later (`Apiary.Stages.sweep/3`).
  @moduledoc false

  defexception message: "the newest questions of the work item cannot be read"
end
