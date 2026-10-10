defmodule ApiaryWeb.AttemptLimits do
  @moduledoc """
  The limits on signing in and on the pages a link opens, each a token bucket of
  `Apiary.Runs.RateLimit`: a number at once (`burst`), then one more every so often
  (`rate`, in tokens a second).

    * **Log-in with a password** (`password_log_in/2`): 5 per address, then 1 a minute;
      and 20 per client address, then 1 every 3 seconds.
    * **A log-in link asked for** (`link_request/1`): 3 per address, then 1 every 5
      minutes.
    * **A page a link opens** (`link_page/1`), an invitation's, a password link's or the
      set-up page (`ApiaryWeb.SetupLive`): 20 per client address, then 1 every 3 seconds,
      the pages together. Each load of the page counts, and so does its live connection.

  An address is keyed by the SHA-256 hash of a form at least as coarse as the accounts
  table's comparison (lowercased, NFKD, without combining marks), never by the address
  itself. Every attempt counts, before anything is looked up: an address with an account
  and one without spend their buckets alike, and past them get the same answer,
  `message/0`, as soon. A log-in with a password spends its client's bucket first, and
  the address's only when the client's allowed it: a client past its own limit spends no
  one else's. The client address is `ApiaryWeb.Origin`'s, which reads `X-Forwarded-For`
  only from the proxies `TRUSTED_PROXIES` names; an IPv6 one counts with the rest of its
  /64, which one machine is commonly given whole.

  The numbers can be changed under `config :apiary, #{inspect(__MODULE__)}`, one keyword
  list of `rate` and `burst` per bucket: `:password_address`, `:password_client`,
  `:link_address` and `:link_page_client`. A bucket lives on its node, so on several nodes
  each one allows as many.
  """
  use Gettext, backend: ApiaryWeb.Gettext
  use ApiaryWeb, :verified_routes

  alias Apiary.Runs.RateLimit

  @defaults [
    password_address: [rate: 1 / 60, burst: 5],
    password_client: [rate: 1 / 3, burst: 20],
    link_address: [rate: 1 / 300, burst: 3],
    link_page_client: [rate: 1 / 3, burst: 20]
  ]

  @doc """
  A log-in with a password for `email`, from `client` (`ApiaryWeb.Origin`'s
  `remote_ip`): `:ok`, or `:limited` once either bucket is empty. The client's bucket is
  spent first, and the address's only when the client's allowed it. A log-in without an
  address as text, `email` nil, spends the client's bucket alone.
  """
  @spec password_log_in(String.t() | nil, String.t() | nil) :: :ok | :limited
  def password_log_in(email, client) do
    with :ok <- spend(:password_client, client_key(client)) do
      if is_binary(email), do: spend(:password_address, address_key(email)), else: :ok
    end
  end

  @doc "A log-in link asked for `email`: `:ok`, or `:limited`."
  @spec link_request(String.t()) :: :ok | :limited
  def link_request(email), do: spend(:link_address, address_key(email))

  @doc """
  A page a link opens, loaded from `client` (`ApiaryWeb.Origin`'s `remote_ip`): `:ok`,
  or `:limited`.
  """
  @spec link_page(String.t() | nil) :: :ok | :limited
  def link_page(client), do: spend(:link_page_client, client_key(client))

  @doc """
  A LiveView's mount of a page a link opens, counted from where its socket comes from:
  `{:ok, socket}`, or `{:limited, socket}` redirected with `message/0`, to the log-in
  page when signed out and to `/` when signed in. Nothing of the link is looked up then.
  """
  @spec link_page_mount(Phoenix.LiveView.Socket.t()) ::
          {:ok | :limited, Phoenix.LiveView.Socket.t()}
  def link_page_mount(socket) do
    origin = ApiaryWeb.Origin.from_socket(socket) || %{}

    case link_page(origin[:remote_ip]) do
      :ok ->
        {:ok, socket}

      :limited ->
        to =
          if match?(%{user: %{}}, socket.assigns[:current_scope]),
            do: ~p"/",
            else: ~p"/users/log-in"

        {:limited,
         socket
         |> Phoenix.LiveView.put_flash(:error, message())
         |> Phoenix.LiveView.redirect(to: to)}
    end
  end

  @doc "The one answer past any of the limits, whatever the address."
  @spec message() :: String.t()
  def message, do: gettext("Too many attempts. Try again in a few minutes.")

  defp spend(bucket, key) do
    case RateLimit.check({__MODULE__, bucket, key}, limit(bucket)) do
      :ok -> :ok
      {:error, _seconds} -> :limited
    end
  end

  defp limit(bucket) do
    configured = Application.get_env(:apiary, __MODULE__, [])

    @defaults
    |> Keyword.fetch!(bucket)
    |> Keyword.merge(Keyword.take(Keyword.get(configured, bucket, []), [:rate, :burst]))
  end

  # A client's bucket: its address as `ApiaryWeb.Origin` wrote it, an IPv4 one as it is,
  # an IPv6 one as its /64, `2001:db8:0:1::/64`, since one machine is commonly given a
  # whole /64 and may write any address in it.
  @doc false
  def client_key(client) when is_binary(client) do
    case :inet.parse_strict_address(String.to_charlist(client)) do
      {:ok, {a, b, c, d, _, _, _, _}} ->
        List.to_string(:inet.ntoa({a, b, c, d, 0, 0, 0, 0})) <> "/64"

      _ipv4_or_other ->
        client
    end
  end

  def client_key(client), do: client

  # At least as coarse as citext's comparison, so an address the accounts table takes
  # for the same one is the same bucket, whatever the database's locale lowercases
  # `İ` to: lowercased, decomposed by compatibility (NFKD), stripped of its combining
  # marks, lowercased again. Coarser only merges buckets, which limits more, never less.
  @doc false
  def address_key(email) when is_binary(email) do
    folded =
      if String.valid?(email) do
        email
        |> String.downcase()
        |> :unicode.characters_to_nfkd_binary()
        |> String.replace(~r/\p{Mn}/u, "")
        |> String.downcase()
      else
        email
      end

    :crypto.hash(:sha256, folded)
  end

  def address_key(_email), do: :crypto.hash(:sha256, "")
end
