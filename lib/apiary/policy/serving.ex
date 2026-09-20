defmodule Apiary.Policy.Serving do
  @moduledoc """
  The run configuration as the wire reads it: for a runner, which has an access key's hive
  and no user. Everything a runner names is untrusted: a forge and a repository are
  bounded strings compared to stored ones and nothing more.

  `fetch/3` is the run configuration endpoint's: the stored bytes and their digest for the
  labelled repository, the baseline's for a repository the hive does not know or that has
  no rules of its own. The hive's first baseline (`observe`, nothing allowed) is rendered
  when it is first needed.

  `digest_for/4` is the events endpoint's, on the path the receiver answers from, so it
  reads and never renders (but for that first baseline): the digest in force for the
  run's repository. A run's repository is known once its start is projected, which is
  after the receiver answers; until then it is taken from the start event when the batch
  holds it, and a run that names none yet (its ping) is answered the digest it reported
  when that is one in force in the hive, the baseline's otherwise. A runner that is told
  a digest it does not hold fetches again, so the answer errs towards the digest it holds
  only while the repository is unknown, and the next batch says the truth.
  """

  import Ecto.Query, warn: false

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Policy
  alias Apiary.Policy.RunConfiguration
  alias Apiary.Repo
  alias Apiary.Runs.{Batch, Repository, Run}

  @label_max 512
  @digest ~r/\Asha256=[0-9a-f]{64}\z/
  @started "ai.qory.run.started"

  @doc "The most bytes of a forge or a repository label that is looked up; a longer one names no repository."
  def label_max, do: @label_max

  @doc "The run configuration in force for the key's hive and the labelled repository."
  @spec fetch(AccessKey.t(), term, term) :: {:ok, RunConfiguration.t()} | {:error, term}
  def fetch(%AccessKey{organisation_id: organisation_id, hive_id: hive_id}, forge, repository) do
    Policy.in_force(organisation_id, hive_id, repository_id(hive_id, forge, repository))
  end

  @doc """
  The digest in force for a run of the key's hive, or nil when it cannot be read: the
  answer then carries no such header, which means nothing to a runner. `run` is the run's
  row or nil (a closed run is looked up by the batch's subject).
  """
  @spec digest_for(AccessKey.t(), Run.t() | nil, Batch.t(), String.t() | nil) :: String.t() | nil
  def digest_for(%AccessKey{} = access_key, run, %Batch{} = batch, reported) do
    %AccessKey{organisation_id: organisation_id, hive_id: hive_id} = access_key

    with nil <- known_repository(hive_id, run, batch),
         nil <- started_repository(hive_id, batch),
         true <- is_binary(reported) and Regex.match?(@digest, reported),
         true <- in_force?(hive_id, reported) do
      reported
    else
      repository_id when is_binary(repository_id) ->
        digest(organisation_id, hive_id, repository_id)

      _unknown ->
        digest(organisation_id, hive_id, nil)
    end
  rescue
    _exception -> nil
  end

  defp digest(organisation_id, hive_id, repository_id) do
    case Policy.in_force(organisation_id, hive_id, repository_id) do
      {:ok, %RunConfiguration{digest: digest}} -> digest
      {:error, _reason} -> nil
    end
  end

  defp known_repository(_hive_id, %Run{repository_id: repository_id}, _batch)
       when is_binary(repository_id),
       do: repository_id

  defp known_repository(_hive_id, %Run{}, _batch), do: nil

  defp known_repository(hive_id, nil, %Batch{subject: subject}) do
    Repo.one(
      from r in Run,
        where: r.hive_id == ^hive_id and r.run_id == ^subject,
        select: r.repository_id
    )
  end

  defp started_repository(hive_id, %Batch{events: events}) do
    with %{data: %{"labels" => %{"forge" => forge, "repository" => repository}}} <-
           Enum.find(events, &(&1.type == @started)) do
      repository_id(hive_id, forge, repository)
    else
      _ -> nil
    end
  end

  # Whether the digest is the newest version's of the baseline or of any repository.
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
                    n.repository_id,
                    parent_as(:configuration).repository_id
                  )
          )
    )
  end

  defp repository_id(hive_id, forge, repository) do
    if label?(forge) and label?(repository) do
      Repo.one(
        from p in Repository,
          where: p.hive_id == ^hive_id and p.forge == ^forge and p.path == ^repository,
          select: p.id
      )
    end
  end

  defp label?(label) do
    is_binary(label) and label != "" and byte_size(label) <= @label_max and String.valid?(label) and
      not String.contains?(label, <<0>>)
  end
end
