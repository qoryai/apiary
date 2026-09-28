defmodule Apiary.Job.Log do
  @moduledoc """
  One log line for every job that fails, is cancelled or is discarded, and for every run of
  one of the queue's plugins that fails.

  Oban reports these as telemetry events once the job's `perform/1` has returned, when
  `Apiary.Job` has already put back the process's Logger metadata, so each line is given
  the job's `organisation_id`, `workspace_id` and `user_id` from its arguments itself
  (`Apiary.LogMetadata.metadata/3`). A job's line names the worker, the job's id, the
  attempt out of the attempts it has, the queue, the state and the kind of the failure, and
  the module of the error: never the arguments, and never the error's message, which can
  quote a value from them. A job that succeeds or is snoozed writes nothing.

    * `failure`, a failure that will be retried, is a warning; `discard`, the last attempt
      failed, is an error.
    * `cancelled` is a warning, with the reason when it is an atom, as `Apiary.Job`'s are
      (`scope_gone`, `invalid_arguments`).
    * A plugin's failure is an error naming the plugin and the error's module.

  Oban's own default logger is not used: it logs a job's arguments and the error's message.
  """

  require Logger

  alias Apiary.LogMetadata

  @handler_id "apiary-job-log"

  @events [
    [:oban, :job, :exception],
    [:oban, :job, :stop],
    [:oban, :plugin, :exception],
    [:oban, :plugin, :stop]
  ]

  @doc "Attaches the handler to Oban's job and plugin events. Called once, at boot."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  # :telemetry detaches a handler that raises, and every later failure would go unlogged:
  # whatever goes wrong here is one line of its own, and the handler stays.
  def handle_event(event, measurements, meta, config) do
    handle(event, measurements, meta, config)
  rescue
    exception ->
      Logger.error(
        "job log failed event=#{inspect(event)} error=#{inspect(exception.__struct__)}"
      )

      :ok
  end

  defp handle([:oban, :job, :exception], _measurements, %{job: job} = meta, _config) do
    level = if meta[:state] == :discard, do: :error, else: :warning

    log(level, job, "job failed", meta[:state],
      kind: meta[:kind],
      error: error_name(meta[:reason] || meta[:error])
    )
  end

  defp handle([:oban, :job, :stop], _measurements, %{job: job, state: state} = meta, _config)
       when state in [:cancelled, :discard] do
    level = if state == :discard, do: :error, else: :warning
    verb = if state == :discard, do: "job discarded", else: "job cancelled"
    log(level, job, verb, state, reason: reason(meta[:result]))
  end

  defp handle([:oban, :plugin, :exception], _measurements, meta, _config) do
    Logger.error(
      "job plugin failed plugin=#{inspect(meta[:plugin])} kind=#{meta[:kind]} " <>
        "error=#{error_name(meta[:reason])}"
    )
  end

  defp handle([:oban, :plugin, :stop], _measurements, %{error: error} = meta, _config)
       when not is_nil(error) do
    Logger.error("job plugin failed plugin=#{inspect(meta[:plugin])} error=#{error_name(error)}")
  end

  defp handle(_event, _measurements, _meta, _config), do: :ok

  defp log(level, %Oban.Job{} = job, verb, state, fields) do
    extra =
      for {key, value} <- fields, not is_nil(value), into: "", do: " #{key}=#{value}"

    Logger.log(
      level,
      "#{verb} worker=#{job.worker} id=#{job.id} attempt=#{job.attempt}/#{job.max_attempts} " <>
        "queue=#{job.queue} state=#{state}" <> extra,
      metadata(job.args)
    )
  end

  defp metadata(%{} = args),
    do: LogMetadata.metadata(args["organisation_id"], args["workspace_id"], args["user_id"])

  defp metadata(_args), do: []

  # The module of an exception, or the kind of value for anything else: never its message.
  defp error_name(%{__struct__: module}), do: inspect(module)
  defp error_name(nil), do: nil
  defp error_name(other) when is_atom(other), do: inspect(other)
  defp error_name(_other), do: "term"

  defp reason({:cancel, reason}) when is_atom(reason), do: reason
  defp reason({:discard, reason}) when is_atom(reason), do: reason
  defp reason(_result), do: nil
end
