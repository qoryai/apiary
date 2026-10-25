defmodule Apiary.WorkCredentialStub do
  @moduledoc """
  An adapter's answers to the run-credential call in the tests (`Req.Test`, under
  `Apiary.Adapters.Calls`), signed under the seed of the adapter's access key and bound
  to the call, as `Apiary.Adapters.Calls` checks them. Each call the stub receives is sent
  to the test as `{:run_credential_call, path, body}`, its body decoded.
  """

  alias Apiary.Contract.{Ed25519, SignedMessage}

  @doc """
  A credential document of the integration contract's answer: `token`, the apply items
  `apply`, and `expires_at` `seconds` after now, none for `nil`.
  """
  def credential(token, apply, seconds \\ 3600) do
    %{"version" => 1, "token" => token, "apply" => apply}
    |> then(fn credential ->
      if seconds do
        expires_at =
          DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

        Map.put(credential, "expires_at", DateTime.to_iso8601(expires_at))
      else
        credential
      end
    end)
  end

  @doc """
  Answers every call with `credential`, signed under `seed`, after it calls `before`, a
  function of no arguments, in the stub's process.
  """
  def issue(seed, credential, before \\ fn -> :ok end) do
    body = Jason.encode!(%{"version" => 1, "revision" => 1, "credential" => credential})
    answer(seed, 200, body, before)
  end

  @doc """
  Answers every call with `body`, as given, with `status`, signed under `seed`, after it
  calls `before`.
  """
  def answer(seed, status, body, before \\ fn -> :ok end) do
    Req.Test.stub(Apiary.Adapters.Calls, fn conn ->
      conn = told(conn)
      before.()
      [call_signature] = Plug.Conn.get_req_header(conn, "x-qory-signature-ed25519")
      message = SignedMessage.call_answer(status, call_signature, body)
      signature = Ed25519.encode(:crypto.sign(:eddsa, :none, message, [seed, :ed25519]))

      conn
      |> Plug.Conn.put_resp_header("x-qory-signature-ed25519", signature)
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  @doc "Answers every call after `ms` milliseconds, with an unsigned 504."
  def slow(ms) do
    Req.Test.stub(Apiary.Adapters.Calls, fn conn ->
      conn = told(conn)
      Process.sleep(ms)
      Plug.Conn.send_resp(conn, 504, "")
    end)
  end

  @doc "The calls the stub received so far, oldest first: `{path, body}`."
  def calls do
    receive do
      {:run_credential_call, path, body} -> [{path, body} | calls()]
    after
      0 -> []
    end
  end

  # The stub runs in the attempt's task, whose first caller is the test.
  defp told(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    send(
      hd(Process.get(:"$callers")),
      {:run_credential_call, conn.request_path, Jason.decode!(body)}
    )

    conn
  end
end
