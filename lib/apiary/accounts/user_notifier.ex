defmodule Apiary.Accounts.UserNotifier do
  import Swoosh.Email

  alias Apiary.Mailer
  alias Apiary.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Mailer.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Confirm your new email address for Qory", """

    ==============================

    Hi #{user.email},

    You can change the email address of your Qory account by visiting the URL below:

    #{url}

    If you did not ask for this change, ignore this email.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Your Qory log-in link", """

    ==============================

    Hi #{user.email},

    You can log in to Qory by visiting the URL below:

    #{url}

    The link works once, for 15 minutes. If you did not ask for it, ignore this email.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirm your Qory account", """

    ==============================

    Hi #{user.email},

    You can confirm your Qory account by visiting the URL below:

    #{url}

    If you did not create a Qory account, ignore this email.

    ==============================
    """)
  end

  @doc """
  Deliver an invitation to join an organisation.
  """
  def deliver_invitation(email, inviter, organisation, url) do
    deliver(email, "You are invited to #{organisation.name} on Qory", """

    ==============================

    Hi #{email},

    #{inviter.email} has invited you to join #{organisation.name} on Qory.
    You can accept the invitation by visiting the URL below:

    #{url}

    The invitation is valid for seven days. If you were not expecting it, ignore this email.

    ==============================
    """)
  end
end
