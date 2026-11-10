defmodule Apiary.Runs.RunApi do
  @moduledoc """
  A run's requests to the run API, as pages show them. Forager records each with the rule
  `wall:run-api` and the host `run-api.qory.invalid`, the placeholder a run sends them to,
  which the run's proxy routes to Qory Apiary. A page shows the instance's host in its
  place (`Apiary.Instance.host/0`, in lower case), with no port, and finds the rows by
  either host, in any case. The stored rows stay as Forager recorded them.
  """

  @rule "wall:run-api"
  @placeholder "run-api.qory.invalid"

  @doc "rule/0 is the rule of a request to the run API, `#{@rule}`."
  @spec rule() :: String.t()
  def rule, do: @rule

  @doc "run_api?/1 is whether a connection's rule is the run API's."
  @spec run_api?(String.t() | nil) :: boolean
  def run_api?(rule), do: rule == @rule

  @doc "placeholder/0 is the host a request to the run API is recorded with, `#{@placeholder}`."
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  @doc """
  host/0 is the host a request to the run API shows: the instance's, in lower case, so
  that it is one host with the rows recorded with it however `PUBLIC_URL` is written; the
  placeholder where the instance's URL has no host.
  """
  @spec host() :: String.t()
  def host do
    case Apiary.Instance.host() do
      host when is_binary(host) and host != "" -> String.downcase(host)
      _none -> @placeholder
    end
  end

  @doc """
  host?/1 is whether a host typed into a filter is the instance's, in any case, so that it
  finds the requests to the run API too.
  """
  @spec host?(String.t() | nil) :: boolean
  def host?(host) when is_binary(host), do: String.downcase(host) == host()

  def host?(_host), do: false

  @doc """
  either_host?/1 is whether a host typed into a filter is the instance's or the
  placeholder, in any case: either one finds the requests to the run API.
  """
  @spec either_host?(String.t() | nil) :: boolean
  def either_host?(host) when is_binary(host),
    do: host?(host) or String.downcase(host) == @placeholder

  def either_host?(_host), do: false
end
