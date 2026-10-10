defmodule Apiary.Mail.Password do
  @moduledoc """
  The encryption of the SMTP password an instance admin saves in Instance settings › Mail
  (`Apiary.Mail`): AES-256-GCM (`Apiary.Secrets.Cipher`) under the key
  `Apiary.KeyDerivation` derives for the purpose `:mail`, with a random 96-bit nonce for
  each encryption. `smtp_password_ciphertext` holds the nonce, the ciphertext and the
  tag; `mail_key_id` the key's id, so a password encrypted under a key the instance no
  longer holds, its `APIARY_ENCRYPTION_SECRET` lost or replaced, is told apart from one
  that was changed.

  **The associated data** binds the password to its row and its field, and to where it is
  sent:

      lp("apiary-mail-password-v1") ‖ lp("instance_settings") ‖ lp("true")
        ‖ lp("smtp_password") ‖ lp(relay) ‖ lp(port) ‖ lp(tls) ‖ lp(username, or "")

  the row being the instance's one row of `instance_settings`, whose key is `true`, the
  port in decimal and `lp/1` as `Apiary.Secrets.Cipher.lp/1` has it. A password moved to
  another column, or left in place while the relay, the port, TLS or the username is
  changed in the database, no longer decrypts, so the database alone cannot send the
  password to another server, nor over a connection without TLS. A save that changes any
  of them asks for the password again (`Apiary.Mail.save_settings/3`).

  Nothing here logs, and nothing keeps a key or the password beyond the call.
  """

  alias Apiary.KeyDerivation
  alias Apiary.Mail.Settings
  alias Apiary.Secrets.Cipher

  @label "apiary-mail-password-v1"
  @nonce_bytes 12

  @doc "aad/1 is the associated data of the password of `settings`: see the module's documentation."
  @spec aad(Settings.t()) :: binary
  def aad(%Settings{smtp_relay: relay, smtp_port: port, smtp_tls: tls, smtp_username: username})
      when is_binary(relay) and is_integer(port) and is_binary(tls) do
    IO.iodata_to_binary([
      Cipher.lp(@label),
      Cipher.lp("instance_settings"),
      Cipher.lp("true"),
      Cipher.lp("smtp_password"),
      Cipher.lp(relay),
      Cipher.lp(Integer.to_string(port)),
      Cipher.lp(tls),
      Cipher.lp(username || "")
    ])
  end

  @doc """
  encrypt/2 encrypts `password` for `settings`, under the current `:mail` key:
  `{ciphertext, key_id}`, the ciphertext the nonce, the encrypted password and the tag.
  """
  @spec encrypt(Settings.t(), String.t()) :: {binary, KeyDerivation.key_id()}
  def encrypt(%Settings{} = settings, password) when is_binary(password) do
    {key_id, key} = KeyDerivation.key(:mail)
    {nonce, ciphertext} = Cipher.encrypt(key, aad(settings), password)
    {nonce <> ciphertext, key_id}
  end

  @doc """
  decrypt/1 is the password `settings` holds: `{:ok, password}`; `:none` when it holds
  none; or `:error` when it cannot be read: its key is not the instance's, or the
  ciphertext, or what the associated data binds it to, was changed.
  """
  @spec decrypt(Settings.t()) :: {:ok, String.t()} | :none | :error
  def decrypt(%Settings{smtp_password_ciphertext: nil}), do: :none

  def decrypt(
        %Settings{
          smtp_password_ciphertext: <<nonce::binary-size(@nonce_bytes), ciphertext::binary>>,
          mail_key_id: key_id,
          smtp_relay: relay,
          smtp_port: port,
          smtp_tls: tls
        } = settings
      )
      when is_binary(key_id) and is_binary(relay) and is_integer(port) and is_binary(tls) do
    with {:ok, key} <- KeyDerivation.key(:mail, key_id),
         {:ok, password} <- Cipher.decrypt(key, aad(settings), nonce, ciphertext) do
      {:ok, password}
    else
      _unreadable -> :error
    end
  end

  def decrypt(%Settings{}), do: :error
end
