defmodule ApiaryWeb.HealthController do
  @moduledoc """
  `GET /health` for load balancers and container orchestrators.

  Answers 200 when the database answers `SELECT 1` and 503 otherwise. No
  authentication, no session, never cached.
  """
  use ApiaryWeb, :controller

  def show(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case database_status() do
      :ok ->
        json(conn, %{status: "ok", database: "ok", version: version()})

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "degraded", database: "error"})
    end
  end

  defp database_status do
    case Apiary.Repo.query("SELECT 1", [], timeout: 5_000) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _exception -> :error
  catch
    :exit, _reason -> :error
  end

  defp version do
    :apiary |> Application.spec(:vsn) |> to_string()
  end
end
