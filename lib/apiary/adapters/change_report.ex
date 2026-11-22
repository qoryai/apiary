defmodule Apiary.Adapters.ChangeReport do
  @moduledoc false

  # ChangeReport reads what an adapter reports about a `change_request` entry of its change
  # feed: its reply, `POST /v1/work-items/changes/submitted` (`changes-submitted.schema.json`),
  # and its failure, the `change_request_id` branch of `POST /v1/work-items/changes/failed`
  # (`changes-failed.schema.json`), both of the integrations contract, vendored under
  # `priv/contract/integration/`.
  #
  # The body is a decoded map that has no member twice at any depth (`Apiary.Adapters.Wire.decode/1`).
  # The schema checks it, and it ignores a member that it does not define. The code adds the
  # rules that a schema cannot state, as `changes-submitted.schema.json` has them: the reply's
  # `data` is at most 786432 bytes serialized, and an `address.url` is on the system of
  # `target.address.system` when the target has an address: `https`, that host in lower case with
  # no port, query or fragment, and a path that is not empty or `/` alone. A bracketed or
  # percent-encoded host equals no system.
  #
  # Pure functions: nothing here touches the database, and no value that was sent goes into
  # an error. Anything not accepted is `:error`.

  alias Apiary.Adapters.Wire
  alias Apiary.Artifacts.Version
  alias Apiary.Kinds.Schema

  @max_data 786_432
  @url ~r{\Ahttps://([^/?#:@\[\]%]+)(/[^?#]+)\z}

  @typedoc "A reply to a change request."
  @type submitted :: %{
          time: DateTime.t(),
          change_request_id: String.t(),
          collection: String.t(),
          reply: map
        }

  @typedoc "A report that a change request failed."
  @type failed :: %{
          time: DateTime.t(),
          change_request_id: String.t(),
          collection: String.t(),
          reason: :not_permitted | :unreachable | :target_gone | :too_long | :refused,
          detail: String.t() | nil
        }

  @doc """
  submitted/1 is `{:ok, report}` for a reply as the contract has it, with the members of the
  reply that the entry stores (`action`, `address` and `data`, those the body has) as
  `reply`, or `:error`.
  """
  @spec submitted(term) :: {:ok, submitted} | :error
  def submitted(%{} = body) do
    with true <- valid?(body, "changes-submitted.schema.json"),
         {:ok, time} <- Wire.time(body["time"]),
         true <- data_fits?(body),
         true <- address_on_system?(body) do
      {:ok,
       %{
         time: time,
         change_request_id: body["change_request_id"],
         collection: body["target"]["collection"],
         reply: Map.take(body, ~w(action address data))
       }}
    else
      _ -> :error
    end
  end

  def submitted(_body), do: :error

  @doc """
  failed/1 is `{:ok, report}` for a report about a change request as the contract has it
  (one with `change_request_id`, `target` and a reason of a change request), or `:error`,
  for any other body, a report about a comment included.
  """
  @spec failed(term) :: {:ok, failed} | :error
  def failed(%{"change_request_id" => _id} = body) do
    with true <- valid?(body, "changes-failed.schema.json"),
         {:ok, time} <- Wire.time(body["time"]) do
      {:ok,
       %{
         time: time,
         change_request_id: body["change_request_id"],
         collection: body["target"]["collection"],
         reason: Enum.find(Version.delivery_failures(), &(Atom.to_string(&1) == body["reason"])),
         detail: body["detail"]
       }}
    else
      _ -> :error
    end
  end

  def failed(_body), do: :error

  defp valid?(body, file) do
    root = Schema.file!(["contract", "integration", file])
    match?({:ok, _body}, JSV.validate(body, root, cast: false))
  end

  defp data_fits?(%{"data" => data}), do: byte_size(Jason.encode!(data)) <= @max_data
  defp data_fits?(_body), do: true

  defp address_on_system?(%{
         "address" => %{"url" => url},
         "target" => %{"address" => %{"system" => system}}
       }) do
    case Regex.run(@url, url) do
      [_all, host, path] -> host == system and host == String.downcase(host) and path != "/"
      nil -> false
    end
  end

  defp address_on_system?(_body), do: true
end
