defmodule Apiary.Policy.Serving do
  @moduledoc """
  The run configuration as the wire reads it: for a runner, which has an access key's hive
  and no user. Everything a runner names is untrusted: its labels are bounded strings,
  read by the hive's body (`Apiary.Body`) and compared to stored ones, nothing more.

  A hive serves a run configuration only once somebody has made its policy
  (`Apiary.Policy.managed?/1`). Until then `fetch/2` is `{:error, :unmanaged}`,
  `digest_for/4` is nil, and nothing is rendered from here: the hive's machines use the
  policy of their own `runner.yaml`. The same holds on an instance, or for a hive, without
  the `security` feature (`Apiary.Features`): nothing is served, the discovery document
  names no `run` section, and the policy is absent from the contract.

  `fetch/2` is the run configuration endpoint's: the stored bytes and their digest for the
  target the labels name, the baseline's for a target the hive does not know or that has
  no rules of its own. A managed hive always has a baseline: its first change rendered one,
  and nothing here renders anything.

  `digest_for/4` is the events endpoint's, on the path the receiver answers from, so it
  reads and never renders: the digest in force for the run's target, after the read
  that says the hive is managed. Each is a read of an index; a target without a
  configuration of its own costs one more, for the baseline's. A run's target is known
  once its start is projected, which is after the receiver answers; until then it is
  taken from the start event when the batch holds it, and a run that names none yet (its
  ping) is answered the digest it reported when that is one in force in the hive, the
  baseline's otherwise. A runner that is told a digest it does not hold fetches again, so
  the answer errs towards the digest it holds only while the target is unknown, and the
  next batch says the truth.
  """

  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Body
  alias Apiary.Policy
  alias Apiary.Policy.RunConfiguration
  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Run, Target}

  @digest ~r/\Asha256=[0-9a-f]{64}\z/
  @started "dev.qory.run.started"

  @doc """
  The run configuration in force for the key's hive and the target a run's `labels` name,
  by the hive's body. `labels` is untrusted, any map: a label that is not a string names
  nothing.
  """
  @spec fetch(AccessKey.t(), term) :: {:ok, RunConfiguration.t()} | {:error, term}
  def fetch(%AccessKey{organisation_id: organisation_id, hive_id: hive_id} = key, labels) do
    if managed?(key),
      do: Policy.in_force(organisation_id, hive_id, target_id(hive_id, labels)),
      else: {:error, :unmanaged}
  end

  @doc """
  Whether the key's hive serves a run configuration: `security` is on for the key
  (`Apiary.Features.on?/2`) and `Apiary.Policy.managed?/1` holds for its hive.
  """
  @spec managed?(AccessKey.t()) :: boolean
  def managed?(%AccessKey{hive_id: hive_id} = key),
    do: Apiary.Features.on?(key, :security) and Policy.managed_hive?(hive_id)

  @doc """
  The digest in force for a run of the key's managed hive (the caller has asked
  `managed?/1`), or nil when it cannot be read: the answer then carries no such header,
  which means nothing to a runner. `run` is the run's
  row or nil (a closed run is looked up by the batch's subject).
  """
  @spec digest_for(AccessKey.t(), Run.t() | nil, Batch.t(), String.t() | nil) :: String.t() | nil
  def digest_for(%AccessKey{} = access_key, run, %Batch{} = batch, reported) do
    %AccessKey{organisation_id: organisation_id, hive_id: hive_id} = access_key

    with nil <- known_target(hive_id, run, batch),
         nil <- started_target(hive_id, batch),
         true <- is_binary(reported) and Regex.match?(@digest, reported),
         true <- in_force?(hive_id, reported) do
      reported
    else
      target_id when is_binary(target_id) ->
        digest(organisation_id, hive_id, target_id)

      _unknown ->
        digest(organisation_id, hive_id, nil)
    end
  rescue
    _exception -> nil
  end

  defp digest(organisation_id, hive_id, target_id) do
    case Policy.in_force(organisation_id, hive_id, target_id) do
      {:ok, %RunConfiguration{digest: digest}} -> digest
      {:error, _reason} -> nil
    end
  end

  defp known_target(_hive_id, %Run{target_id: target_id}, _batch)
       when is_binary(target_id),
       do: target_id

  defp known_target(_hive_id, %Run{}, _batch), do: nil

  defp known_target(hive_id, nil, %Batch{subject: subject}) do
    Repo.one(
      from r in Run,
        where: r.hive_id == ^hive_id and r.run_id == ^subject,
        select: r.target_id
    )
  end

  defp started_target(hive_id, %Batch{events: events}) do
    with %{data: %{"labels" => labels}} <- Enum.find(events, &(&1.type == @started)) do
      target_id(hive_id, labels)
    else
      _ -> nil
    end
  end

  # Whether the digest is the newest version's of the baseline or of any target.
  defp in_force?(hive_id, digest) do
    Repo.exists?(
      from c in RunConfiguration,
        as: :configuration,
        where: c.hive_id == ^hive_id and c.digest == ^digest,
        where:
          not exists(
            from n in RunConfiguration,
              where:
                n.hive_id == parent_as(:configuration).hive_id and
                  n.version > parent_as(:configuration).version and
                  fragment(
                    "? IS NOT DISTINCT FROM ?",
                    n.target_id,
                    parent_as(:configuration).target_id
                  )
          )
    )
  end

  # The labels name a target only by the hive's body, the rule the projector follows
  # too (`Apiary.Runs.Fold`): the wire and the projector pick the same, or none.
  defp target_id(hive_id, labels) do
    case Body.target(hive_id, labels) do
      {:ok, %{system: system, path: path}} ->
        Repo.one(
          from t in Target,
            where: t.hive_id == ^hive_id and t.system == ^system and t.path == ^path,
            select: t.id
        )

      :none ->
        nil
    end
  end
end
