defmodule ApiaryWeb.Contract.ConfigurationController do
  @moduledoc """
  The configuration document of the server contract, version 1: where the
  events go and where the run configuration is. Reached only through
  `ApiaryWeb.Contract.SignedRequest`.
  """
  use ApiaryWeb, :controller

  @version 1

  def show(conn, _params) do
    base = ApiaryWeb.Endpoint.url()

    json(conn, %{
      version: @version,
      events: %{url: base <> "/v1/events", types: ["*"]},
      run: %{url: base <> "/v1/run-configuration"}
    })
  end
end
