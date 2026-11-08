defmodule Apiary.Stages.VerdictUnreadable do
  # Raised when the stage runner reads the end of a run that ended by its exit and the
  # store cannot read the file of the newest verdict the run pushed
  # (`Apiary.Stages.reported_verdict/1`). The end is read again later, on the same paths
  # as for `Apiary.Stages.QuestionsUnreadable`.
  @moduledoc false

  defexception message: "the newest verdict of the run cannot be read"
end
