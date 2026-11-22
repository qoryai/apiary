defmodule Apiary.Artifacts.Delivery do
  @moduledoc false

  # Where the delivery of a version to an adapter stands, stored on the version
  # (`Apiary.Artifacts.Version`: `delivery`, `delivery_reply`, `delivery_failure` and
  # `delivery_at`). A delivery is one `change_request` entry of the adapter's change feed,
  # for the version's target.
  #
  # A version's target and type are those of its artifact: an artifact is unique per work
  # item, type and name, and a delivered output's name is the target's, so the
  # versions of one artifact are the versions for one target and type.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Artifacts.Version
  alias Apiary.Repo
  alias Apiary.Runs.Target

  # The character rule of a line (`description.schema.json`, `$defs.line`): no control
  # character, no U+2028 or U+2029, no format character other than U+200C and U+200D.
  @line ~r/\A(?:[^\p{Cc}\p{Cf}\x{2028}\x{2029}]|[\x{200C}\x{200D}])*\z/u

  @doc """
  previous_address/1 is the address of `version`'s previous delivery, the `address` of the
  adapter's newest reply for the same target and type, for the entry's `previous.address`:
  a map as the adapter sent it, or nil when no other version of the artifact has a reply,
  or when the newest reply has no address (a reply for an entry that asked for no change).

  The newest reply is the one with the latest `delivery_at`, then the latest
  `inserted_at` of its version. A version with a reply and no `delivery_at` is older than
  every version with one. The version itself is left out. It reads the versions of the
  artifact by `artifact_id`, which the unique index on `artifact_id` and `number` serves.
  """
  @spec previous_address(Version.t()) :: map | nil
  def previous_address(%Version{id: id, artifact_id: artifact_id}) do
    reply =
      Repo.one(
        from v in Version,
          where: v.artifact_id == ^artifact_id and v.id != ^id and not is_nil(v.delivery_reply),
          order_by: [desc_nulls_last: v.delivery_at, desc: v.inserted_at],
          limit: 1,
          select: v.delivery_reply
      )

    reply && reply["address"]
  end

  @doc """
  record_invalid/2 stores that the entry for `version` failed Qory Apiary's check, so
  nothing is sent: `result` is what `Apiary.Adapters.ChangeRequest.validate/1` returned
  for the entry. For `{:error, summary}` it sets `delivery` to `:failed`,
  `delivery_failure` to `:invalid`, `delivery_detail` to the places that the check
  refused and `delivery_at` to the time, and returns the version with them. For `:ok` it changes nothing and returns the version. A version that already
  has a `delivery` is left as it is and gets `{:error, :delivery_set}`, so a delivery that
  was sent, or a reply that was stored, is not overwritten. The run is not stopped: only
  the delivery fails.

  `delivery_detail` is the `instanceLocation` of the first error of the summary that is
  not the entry itself, a JSON Pointer after `#`, such as `#/title`, or `#` when every
  error is at the entry, as for a missing member. It has the bounds of `detail` in
  `changes-failed.schema.json`: a member name with a control character or a format
  character (other than U+200C and U+200D) ends the pointer before it, and the pointer is
  cut to 1000 characters.
  """
  @spec record_invalid(Version.t(), :ok | {:error, map}) ::
          {:ok, Version.t()} | {:error, :delivery_set}
  def record_invalid(%Version{} = version, :ok), do: {:ok, version}

  def record_invalid(%Version{id: id} = version, {:error, %{valid: false, errors: errors}}) do
    at = DateTime.utc_now()
    detail = detail(errors)

    {count, _rows} =
      Repo.update_all(
        from(v in Version, where: v.id == ^id and is_nil(v.delivery)),
        set: [
          delivery: :failed,
          delivery_failure: :invalid,
          delivery_detail: detail,
          delivery_at: at
        ]
      )

    case count do
      1 ->
        {:ok,
         %{
           version
           | delivery: :failed,
             delivery_failure: :invalid,
             delivery_detail: detail,
             delivery_at: at
         }}

      0 ->
        {:error, :delivery_set}
    end
  end

  # The first place of the errors that is not the entry, as `delivery_detail` has it. The
  # check counts code points, not graphemes, so the cut counts them too.
  defp detail(errors) do
    errors
    |> Enum.map(& &1.instanceLocation)
    |> Enum.find("#", &(&1 != "#"))
    |> String.split("/")
    |> Enum.take_while(&Regex.match?(@line, &1))
    |> Enum.join("/")
    |> String.codepoints()
    |> Enum.take(1000)
    |> Enum.join()
  end

  @doc """
  find_sent/3 is the version that the adapter `adapter_id` has an entry for, as an adapter's
  report names it: the version whose `public_id` is `change_request_id`, whose `delivery` is
  `:sent`, and whose `delivery_target_id` is a target of that adapter with the collection
  ref `collection`; nil for any other case, an unknown id, another adapter's version, a
  version not sent and a version whose target is gone included.
  """
  @spec find_sent(Ecto.UUID.t(), String.t(), String.t()) :: Version.t() | nil
  def find_sent(adapter_id, change_request_id, collection),
    do: Repo.one(sent(adapter_id, change_request_id, collection))

  @doc """
  delivered/2 stores the reply `report` of the adapter `adapter_id`
  (`Apiary.Adapters.ChangeReport.submitted/1`) on the version it is about: `delivery` is
  `:delivered`, `delivery_reply` is the report's reply, and `delivery_at` the time. It
  writes only while the version is `:sent` (`find_sent/3`), in one statement, so the first
  stored result wins. `{:ok, :stored}`, or `{:ok, :ignored}` and no change for any other
  case: a report sent again, or late, is never an error.
  """
  @spec delivered(Ecto.UUID.t(), map) :: {:ok, :stored | :ignored}
  def delivered(adapter_id, %{change_request_id: id, collection: collection, reply: reply}) do
    store(adapter_id, id, collection,
      delivery: :delivered,
      delivery_reply: reply,
      delivery_at: DateTime.utc_now()
    )
  end

  @doc """
  failed/2 stores the failure `report` of the adapter `adapter_id`
  (`Apiary.Adapters.ChangeReport.failed/1`) on the version it is about: `delivery` is
  `:failed`, `delivery_failure` is the reason, `delivery_detail` is the adapter's detail, nil
  for none, and `delivery_at` the time. Otherwise as `delivered/2`.
  """
  @spec failed(Ecto.UUID.t(), map) :: {:ok, :stored | :ignored}
  def failed(adapter_id, %{change_request_id: id, collection: collection} = report) do
    store(adapter_id, id, collection,
      delivery: :failed,
      delivery_failure: report.reason,
      delivery_detail: report.detail,
      delivery_at: DateTime.utc_now()
    )
  end

  defp store(adapter_id, id, collection, set) do
    case Repo.update_all(sent(adapter_id, id, collection), set: set) do
      {1, _rows} -> {:ok, :stored}
      {0, _rows} -> {:ok, :ignored}
    end
  end

  defp sent(adapter_id, change_request_id, collection) do
    from v in Version,
      join: t in Target,
      on: t.id == v.delivery_target_id and t.workspace_id == v.workspace_id,
      where: v.public_id == ^change_request_id and v.delivery == :sent,
      where: t.adapter_id == ^adapter_id and t.collection_external_ref == ^collection
  end
end
