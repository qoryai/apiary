defmodule ApiaryWeb.Contract.RunFeatures do
  @moduledoc """
  The features a run's request of the server contract is checked against: the ones the run
  kept when it was claimed (`Apiary.Features.recorded/0`), until it has ended
  (`Apiary.Runs.Run.ended?/2`), so that a run already running finishes with the features
  it started with when an instance admin turns one on or off. Once the run has ended, its
  requests follow the instance's features, but for the calls the contract takes after
  the end, which follow the run's for as long as they are taken.

  The run is the one the request is about, found by the verified access key
  (`Apiary.Runs.Sender.run_query/3`):

    * on a route under `/v1/runs/:run_id`, the path's `run_id`;
    * on the secrets request, `POST /v1/secrets`, the body's `run_id`, read only where a
      feature other than `observability`, which every instance has, is checked;
    * on a node pool's route under `/v1/dispatches/:dispatch_id`, the run that the claim
      of the dispatch registered, a dispatch of the key's pool, whatever the run's state:
      its machine's log and end come after the run ended
      (`Apiary.Runs.Sender.dispatch_recorded/2`);
    * on a gateway's model keys report, `POST /v1/runs/:run_id/model-keys`, the run until
      60 seconds after its end, the window in which its last report is still recorded
      (`Apiary.ModelKeys.Report.recorded/3`).

  A request about no run, about a run the key does not find, or, but for the last two
  cases, about a run that has ended follows the instance's features.
  """

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Features
  alias Apiary.Registry.Credential
  alias Apiary.Runs.{Run, Sender}

  # Where the gate keeps, in the conn, what it read: the features, and on the registry
  # token route, the credential and what its check returned.
  @recorded :run_features
  @credential :run_features_credential

  @doc """
  on?/2 is whether one of `features` is on for the request of `conn`: among the ones the
  run it is about kept when it was claimed, until it has ended, whatever the
  instance has now; or, for a request about no run, about a run that is not found, about a
  run that has ended, or about a run that kept no features, among the instance's
  (`Apiary.Features.on?/1`).
  """
  @spec on?(Plug.Conn.t(), [Features.feature()]) :: boolean
  def on?(conn, features) when is_list(features), do: conn |> gate(features) |> elem(0)

  @doc """
  gate/2 is `on?/2` and `conn` with what it read kept, for the feature gate of a
  controller (`ApiaryWeb.Features`): the controller then reads the features
  (`recorded/1`) and the registry credential's check (`verified_credential/3`) without
  reading them again.
  """
  @spec gate(Plug.Conn.t(), [Features.feature()]) :: {boolean, Plug.Conn.t()}
  def gate(conn, features) when is_list(features) do
    {recorded, conn} = read(conn, features)
    {Enum.any?(features, &Features.on?(&1, recorded)), conn}
  end

  @doc """
  recorded/1 is the names of the features the run that the request of `conn` is about kept
  when it was claimed, until it has ended, or nil: as `on?/2` reads them, or as the gate
  kept them.
  """
  @spec recorded(Plug.Conn.t()) :: [String.t()] | nil
  def recorded(conn), do: conn |> read([]) |> elem(0)

  @doc false
  # verified_credential/3 is `Apiary.Registry.Credential.verify/2` of `username` and
  # `secret`, as the gate of the registry token route checked them for `conn`, else
  # checked now.
  @spec verified_credential(Plug.Conn.t(), String.t(), String.t()) :: {:ok, Run.t()} | :error
  def verified_credential(
        %Plug.Conn{private: %{@credential => {username, secret, verified}}},
        username,
        secret
      ),
      do: verified

  def verified_credential(_conn, username, secret), do: Credential.verify(username, secret)

  defp read(%Plug.Conn{private: %{@recorded => recorded}} = conn, _features),
    do: {recorded, conn}

  defp read(conn, features) do
    {recorded, conn} = recorded(conn, features)
    {recorded, Plug.Conn.put_private(conn, @recorded, recorded)}
  end

  defp recorded(
         %Plug.Conn{
           assigns: %{access_key: %AccessKey{} = key},
           path_params: %{"dispatch_id" => dispatch_id}
         } = conn,
         _features
       ),
       do: {Sender.dispatch_recorded(key, dispatch_id), conn}

  defp recorded(
         %Plug.Conn{
           assigns: %{access_key: %AccessKey{} = key},
           private: %{phoenix_controller: ApiaryWeb.Contract.ModelKeysController},
           path_params: %{"run_id" => run_id}
         } = conn,
         _features
       ),
       do: {Apiary.ModelKeys.Report.recorded(key, run_id, DateTime.utc_now()), conn}

  defp recorded(%Plug.Conn{assigns: %{access_key: %AccessKey{} = key}} = conn, features),
    do: {Sender.recorded(key, run_id(conn, features)), conn}

  defp recorded(
         %Plug.Conn{private: %{phoenix_controller: ApiaryWeb.RegistryTokenController}} = conn,
         _features
       ),
       do: credential_recorded(conn)

  defp recorded(conn, _features), do: {nil, conn}

  defp run_id(%Plug.Conn{path_params: %{"run_id" => run_id}}, _features), do: run_id

  defp run_id(
         %Plug.Conn{
           private: %{phoenix_controller: ApiaryWeb.Contract.SecretsController},
           assigns: %{raw_body: body}
         },
         features
       )
       when is_binary(body) and features != [:observability] do
    case Jason.decode(body) do
      {:ok, %{"run_id" => run_id}} -> run_id
      _other -> nil
    end
  end

  defp run_id(_conn, _features), do: nil

  # A request of the private image registry's token route, which has no access key, is
  # about the run whose registry credential it contains, as the route reads it
  # (`ApiaryWeb.RegistryTokenController`). The check is kept in the conn for the
  # controller.
  defp credential_recorded(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {username, secret} when username != "" and secret != "" ->
        verified = Credential.verify(username, secret)
        conn = Plug.Conn.put_private(conn, @credential, {username, secret, verified})

        case verified do
          {:ok, %Run{} = run} -> {Run.kept_features(run), conn}
          :error -> {nil, conn}
        end

      _none ->
        {nil, conn}
    end
  end
end
