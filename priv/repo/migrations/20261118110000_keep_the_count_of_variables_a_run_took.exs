defmodule Apiary.Repo.Migrations.KeepTheCountOfVariablesARunTook do
  use Ecto.Migration

  # A run of the queue ended `variables_invalid` because its workspace and target set more
  # variables than a run takes, or more than 64 KiB of them, keeps the count or the size as
  # `end_detail`, `names_<count>` or `bytes_<bytes>` (`Apiary.Dispatches.Handover`), which
  # its stop cause and its work item's words read. The check of `end_detail` took the cause
  # `run_refused` and the cause `harness_unresolved` only; it takes this one too.
  #
  # Rolled back, the check is as before, and the detail of a run ended `variables_invalid` is
  # set to NULL first: its words are then the general ones, that one of its variables breaks
  # its rule.
  @causes ["run_refused", "harness_unresolved"]
  @cause "variables_invalid"

  def up, do: end_detail(@causes ++ [@cause])

  def down do
    execute "UPDATE dispatch_runs SET end_detail = NULL WHERE end_cause = '#{@cause}'"
    end_detail(@causes)
  end

  # The check of `end_detail`: a code, on a run ended for one of `causes` only.
  defp end_detail(causes) do
    list = Enum.map_join(causes, ", ", &"'#{&1}'")

    drop constraint(:dispatch_runs, :dispatch_runs_end_detail_check)

    create constraint(:dispatch_runs, :dispatch_runs_end_detail_check,
             check:
               "end_detail IS NULL OR (COALESCE(end_cause IN (#{list}), false) " <>
                 "AND end_detail ~ '^[a-z][a-z0-9_]{0,63}$')"
           )
  end
end
