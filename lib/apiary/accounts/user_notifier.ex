defmodule Apiary.Accounts.UserNotifier do
  @moduledoc """
  The mail sent to people. A mail to a user is written for its recipient, in the user's
  language (`ApiaryWeb.Lingo.with_locale/3`), whichever process sends it; none of them is
  about a workspace, so it reads the default domain's words. An invitation goes to an
  address that may have no account yet, so it is written in the calling process's locale:
  a request or a LiveView has already set the inviter's (`ApiaryWeb.Lingo`).
  """
  use Gettext, backend: ApiaryWeb.Gettext
  import Swoosh.Email

  alias Apiary.Mailer
  alias Apiary.Accounts.User
  alias Apiary.Organisations.Organisation

  # Delivers the email using the application mailer. The body's paragraphs are whole,
  # translated sentences, set between the rules the tests and mail clients expect.
  defp deliver(recipient, subject, paragraphs) do
    body = """

    ==============================

    #{Enum.join(paragraphs, "\n\n")}

    ==============================
    """

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
    ApiaryWeb.Lingo.with_locale(nil, user, fn ->
      deliver(user.email, gettext("Confirm your new email address for Qory Apiary"), [
        gettext("Hi %{email},", email: user.email),
        gettext(
          "You can change the email address of your Qory Apiary account by visiting the URL below:"
        ),
        url,
        gettext("If you did not ask for this change, ignore this email.")
      ])
    end)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    ApiaryWeb.Lingo.with_locale(nil, user, fn ->
      case user do
        %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
        _ -> deliver_magic_link_instructions(user, url)
      end
    end)
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, gettext("Your Qory Apiary log-in link"), [
      gettext("Hi %{email},", email: user.email),
      gettext("You can log in to Qory Apiary by visiting the URL below:"),
      url,
      gettext(
        "The link works once, for 15 minutes. If you did not ask for it, ignore this email."
      )
    ])
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, gettext("Confirm your Qory Apiary account"), [
      gettext("Hi %{email},", email: user.email),
      gettext("You can confirm your Qory Apiary account by visiting the URL below:"),
      url,
      gettext("If you did not create a Qory Apiary account, ignore this email.")
    ])
  end

  @doc """
  Delivers an invitation to join an organisation. Nothing in it is text an inviter or an
  organisation's owners chose but the organisation's name, which is data inside a
  sentence Qory writes, in quotation marks, with its format characters taken out
  (`Apiary.Organisations.Organisation.displayable_name/1`): not in the subject, not as a
  heading, not as the text of a link, and carrying no web address, which the name's rules
  refuse; a mail client may still link a bare domain in it. The inviter's address is not
  in it either, since its local part is theirs to choose. The link is the bare URL, on a
  line of its own.
  """
  def deliver_invitation(email, organisation, url) do
    deliver(
      email,
      gettext("Your invitation to Qory Apiary"),
      [
        gettext("Hi %{email},", email: email),
        gettext(
          "You are invited to join the organisation “%{organisation}” on Qory Apiary. You can accept the invitation by visiting the URL below:",
          organisation: Organisation.displayable_name(organisation.name)
        ),
        url,
        gettext(
          "The invitation is valid for seven days. If you were not expecting it, ignore this email."
        )
      ]
    )
  end
end
