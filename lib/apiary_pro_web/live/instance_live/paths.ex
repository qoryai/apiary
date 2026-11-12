defmodule ApiaryProWeb.InstanceLive.Paths do
  @moduledoc """
  Where Instance settings' pages are: its two sections, Organisations
  (`ApiaryProWeb.InstanceLive.Organisations`) and Accounts
  (`ApiaryProWeb.InstanceLive.Accounts`), and the pages and in-place confirmations of
  each. The pages take every path of the Instance from here and write none themselves,
  so the Instance moves by changing this module and the router.

  The Instance is a separate level, under `/instance`, with no organisation in its path
  (`ApiaryWeb.Routes.instance_routes/1`). Its former addresses, under `/:org/instance`,
  lead here (`ApiaryProWeb.InstanceRedirectController`).
  """
  use ApiaryProWeb, :verified_routes

  @acts [:kind, :purge, :suspend, :transfer, :features]

  @doc """
  organisations/1 is the Organisations section, with the list's views, search, filter
  and order (`query`, a keyword list of strings, each left out when nil, empty or false).
  """
  @spec organisations(Enumerable.t()) :: String.t()
  def organisations(query \\ []), do: with_query(~p"/instance/organisations", query)

  @doc "new_organisation/0 is the page that creates an organisation, or an operator."
  @spec new_organisation() :: String.t()
  def new_organisation, do: ~p"/instance/organisations/new"

  @doc """
  organisation/2 is an act on the organisation of the id: a page (`:transfer`,
  `:features`) or a confirmation in place on its row (`:kind`, `:purge`, `:suspend`).
  """
  @spec organisation(String.t(), atom) :: String.t()
  def organisation(id, act) when act in @acts do
    case act do
      :kind -> ~p"/instance/organisations/#{id}/kind"
      :purge -> ~p"/instance/organisations/#{id}/purge"
      :suspend -> ~p"/instance/organisations/#{id}/suspend"
      :transfer -> ~p"/instance/organisations/#{id}/transfer"
      :features -> ~p"/instance/organisations/#{id}/features"
    end
  end

  @doc "accounts/1 is the Accounts section, with the list's view and search."
  @spec accounts(Enumerable.t()) :: String.t()
  def accounts(query \\ []), do: with_query(~p"/instance/accounts", query)

  @doc "account/2 is the suspension of the account of the id, confirmed in place on its row."
  @spec account(String.t(), :suspend) :: String.t()
  def account(id, :suspend), do: ~p"/instance/accounts/#{id}/suspend"

  @doc """
  moved/2 is where a former address of the Instance, `/:org/instance` and the segments
  after it (`rest`), is now, with its query: nil for one that never was. `/:org/instance`
  was one page of both sections, which took the accounts' view and search as `accounts`
  and `aq`: with either, it is Accounts with them as its `view` and `q`.
  """
  @spec moved([String.t()], String.t()) :: String.t() | nil
  def moved([], query) when query not in [nil, ""] do
    params = Plug.Conn.Query.decode(query)
    view = if params["accounts"] == "suspended", do: "suspended"

    q =
      case params["aq"] do
        q when is_binary(q) -> if String.trim(q) != "", do: String.trim(q)
        _none -> nil
      end

    if view || q,
      do: accounts(view: view, q: q),
      else: organisations() <> "?" <> query
  end

  def moved(rest, query) do
    path =
      case rest do
        [] ->
          organisations()

        ["new"] ->
          new_organisation()

        ["accounts"] ->
          accounts()

        ["accounts", id, "suspend"] ->
          account(id, :suspend)

        [id, act] when act in ~w(kind purge suspend transfer features) ->
          organisation(id, String.to_existing_atom(act))

        _other ->
          nil
      end

    cond do
      is_nil(path) -> nil
      query in [nil, ""] -> path
      true -> path <> "?" <> query
    end
  end

  defp with_query(path, query) do
    case Enum.reject(query, fn {_key, value} -> value in [nil, "", false] end) do
      [] -> path
      query -> path <> "?" <> URI.encode_query(query)
    end
  end
end
