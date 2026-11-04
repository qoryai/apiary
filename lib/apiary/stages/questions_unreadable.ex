defmodule Apiary.Stages.QuestionsUnreadable do
  # Raised when the stage runner reads a run of Explore's end and the newest questions of
  # its work item cannot be read (`Apiary.Explore.Questions.current/1`): the end's
  # transaction rolls back, and the end is read again later (`Apiary.Stages`).
  @moduledoc false

  defexception message: "the newest questions of the work item cannot be read"
end
