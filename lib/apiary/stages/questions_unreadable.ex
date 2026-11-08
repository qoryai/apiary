defmodule Apiary.Stages.QuestionsUnreadable do
  # Raised when the stage runner reads a run's end and the newest questions of its work
  # item cannot be read (`Apiary.Explore.Questions.current/1`). A refusal or a
  # lost run rolls back, and the lost-run check tries it again
  # (`Apiary.Dispatches.RunEnd.lose/3`). An exit is stored with no outcome
  # (`Apiary.Dispatches.Settle`); the settle sweep settles it later, and then the stage
  # acts, unless the file becomes unreadable after Settle read it; then the exit rolls
  # back and the lost-run check ends it again. A settle that raises rolls back, and the
  # settle sweep tries it again. A claim, a failed harness walk and a held run store the
  # end, and the stage sweep acts on it later (`Apiary.Stages.sweep/3`).
  @moduledoc false

  defexception message: "the newest questions of the work item cannot be read"
end
