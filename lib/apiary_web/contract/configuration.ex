defmodule ApiaryWeb.Contract.Configuration do
  @moduledoc """
  The configuration document of the server contract, version 1, revision 1, and
  its digest: the one place both come from, so the discovery answer and the
  answer to every batch name the same digest.

  The document says where the events go and, for a workspace whose policy somebody has
  made (`Apiary.Policy.managed?/1`), where the run configuration is fetched from in its
  `run` section (`ApiaryWeb.Contract.RunConfigurationController`). A workspace nobody has
  given a policy is served no `run` section: its machines keep the policy of their own
  `runner.yaml`, and a run under a fetched policy never finds an empty one in its place.
  So the document, and its digest, are one of two, by workspace. The first change of a
  workspace's policy changes the digest its answers carry, and a run in flight fetches the
  document again, finds the section and takes the workspace's policy from then on.
  """

  @version 1
  @events_path "/v1/events"
  @run_path "/v1/run-configuration"

  @doc "The path of the events endpoint, as the document names it under the public URL."
  def events_path, do: @events_path

  @doc "The path of the run configuration endpoint, as the document names it under the public URL."
  def run_path, do: @run_path

  @doc """
  The document as sent, the JSON body and its digest: with the `run` section for a
  workspace whose policy is managed, without it otherwise.
  """
  def document(managed? \\ false) when is_boolean(managed?) do
    url = ApiaryWeb.Endpoint.url()
    events = %{url: url <> @events_path, types: ["*"]}

    body =
      if managed?,
        do: Jason.encode!(%{version: @version, events: events, run: %{url: url <> @run_path}}),
        else: Jason.encode!(%{version: @version, events: events})

    {body, digest(body)}
  end

  @doc "The digest in force for a workspace without a managed policy; `digest(true)` for one with."
  def digest, do: digest(false)

  @doc """
  With a boolean, the digest in force for a workspace, managed or not: what
  `X-Qory-Configuration` carries on every answer. With a document's bytes, their digest.
  """
  def digest(managed?) when is_boolean(managed?), do: managed? |> document() |> elem(1)

  # As the contract states it: `sha256=` and lowercase hex.
  def digest(body) when is_binary(body) do
    "sha256=" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end
end
