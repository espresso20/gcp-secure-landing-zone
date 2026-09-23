# Setting up the lab organization

A checklist for standing up a second GCP organization that this repo can safely build at the
**organization** level. An organization that already holds workloads is never a safe place to
do that, so this calls for a second one.

Work top to bottom. It takes about 45 minutes, most of it waiting on DNS.

---

## Before you start

You need:

- A domain you can add DNS records to, that is **not** already tied to a Cloud Identity or
  Google Workspace account. A different TLD of a domain you already own is fine, since
  `example.dev` and `example.com` are unrelated as far as Google is concerned.
- A credit card for the domain registration. Cloud Identity Free itself costs nothing.
- Your existing GCP billing account, and `roles/billing.user` on it.

You do **not** need a second billing account or a second free trial. Billing accounts are not
locked to one organization.

---

## Part 1: domain

- [ ] **1.1** Confirm the domain is unregistered. No NS records is a reliable signal:
      ```bash
      dig +short NS yourdomain.dev
      ```
      Empty output means almost certainly available. Registered domains always have NS
      delegation at the registry, even parked ones.

- [ ] **1.2** Register it. Porkbun, Namecheap and Cloudflare Registrar are all fine. Check the
      renewal price, not the first-year promo. Some TLDs advertise $1 and renew at $30.

- [ ] **1.3** Decide where DNS lives. Whatever the registrar gives you is fine; you only need
      to add one TXT record. If you already run DNS somewhere (NS1, Cloudflare, Netlify),
      point the domain there so everything stays in one place.

- [ ] **1.4** Confirm DNS is answering before moving on:
      ```bash
      dig +short NS yourdomain.dev
      ```
      Should now return your nameservers. If it is empty, wait. Propagation can take a few
      hours, and every later step depends on this working.

---

## Part 2: Cloud Identity account

> **This is the step that goes wrong.** You are creating a brand-new Cloud Identity account.
> You are not adding a domain to the account you already have.
>
> Adding `yourdomain.dev` as a secondary or alias domain of your existing tenant looks
> reasonable in the admin console and is completely wrong: the domain gets absorbed, you get
> **no new organization**, and you have spent money to acquire another way to spell your
> existing email addresses. Everything already in the organization stays in the blast radius.
>
> If at any point the signup flow asks you to sign in with an existing Google account, you are
> in the wrong flow. Back out.

- [ ] **2.1** Go to the Cloud Identity **Free** signup. Search for "Cloud Identity Free signup"
      if the direct link has moved, because Google reshuffles these URLs. Make sure you land on the
      **Free** edition, not Premium and not Workspace. Premium is a paid tier you do not need,
      and Workspace adds Gmail, which you actively do not want.

- [ ] **2.2** Enter the new domain. When asked for an admin username, `admin@yourdomain.dev` is
      conventional. This becomes a **separate Google identity** with its own password. It is not
      linked to your personal account in any way.

- [ ] **2.3** Set a strong password and store it in your password manager now. You will use this
      account rarely enough to forget it and often enough to be annoyed.

- [ ] **2.4** Turn on 2-step verification for the admin account. It is a super-admin on an
      organization that will hold real IAM policy. Do this before you forget it exists.

- [ ] **2.5** Verify domain ownership via the **TXT record** method. Add the record Google gives
      you at the domain root (`@`), then click verify.

      Verification typically completes in minutes but is allowed to take up to 48 hours. If it
      fails, check you added the record at the apex and not at `www`.

- [ ] **2.6** **Do not** set up Gmail or add MX records. Cloud Identity does not need them. If
      the domain currently serves a website, leaving MX alone means nothing about that site
      changes.

---

## Part 3: the organization

The GCP organization is **created automatically** the first time you access GCP with the new
account. There is no "create organization" button, and looking for one wastes ten minutes.

- [ ] **3.1** Open an incognito or separate browser profile. You are about to be signed into two
      Google accounts, and mixing them is how you apply the wrong thing to the wrong place.

- [ ] **3.2** Go to `console.cloud.google.com` and sign in as `admin@yourdomain.dev`.
      Accept the terms. The organization resource is created behind the scenes.

- [ ] **3.3** Confirm it exists and capture the numeric ID:
      ```bash
      gcloud auth login admin@yourdomain.dev
      gcloud organizations list
      ```
      `DISPLAY_NAME` is your domain. `ID` is the number you need. Write it down.

- [ ] **3.4** **Grant yourself the operational roles.** This is the second thing that surprises
      people: Organization Administrator lets you *manage IAM policy*, but it does not let you
      create folders or projects. You have to grant yourself those explicitly.

      ```bash
      ORG_ID=<the numeric id from 3.3>
      ADMIN=admin@yourdomain.dev
      for ROLE in \
        roles/resourcemanager.organizationAdmin \
        roles/resourcemanager.folderAdmin \
        roles/resourcemanager.projectCreator \
        roles/orgpolicy.policyAdmin \
        roles/logging.configWriter \
        roles/iam.securityAdmin \
        roles/essentialcontacts.admin \
        roles/cloudasset.owner \
        roles/serviceusage.serviceUsageAdmin ; do
        gcloud organizations add-iam-policy-binding "$ORG_ID" \
          --member="user:$ADMIN" --role="$ROLE" --condition=None --quiet
      done
      ```

      `roles/orgpolicy.policyAdmin` is the one people miss, and its absence surfaces as a
      permission error on the very first org policy rather than at login.

---

## Part 4: billing

- [ ] **4.1** Find your existing billing account ID, signed in as your **normal** account:
      ```bash
      gcloud billing accounts list
      ```

- [ ] **4.2** Grant the lab admin `roles/billing.user` on it. Do this as whoever administers
      the billing account:
      ```bash
      gcloud billing accounts add-iam-policy-binding <BILLING_ACCOUNT_ID> \
        --member="user:admin@yourdomain.dev" \
        --role="roles/billing.user"
      ```
      `billing.user` allows *linking projects* to the account. It does not allow spending
      changes or viewing other projects' costs.

- [ ] **4.3** Confirm from the lab account:
      ```bash
      gcloud config configurations activate lab   # see Part 5
      gcloud billing accounts list
      ```
      The account should now be visible. If it is not, the binding has not propagated yet. Give
      it a minute.

- [ ] **4.4** Set a **budget alert on the lab organization** before you build anything. You are
      about to point Terraform at an empty org with a live billing account attached. Console →
      Billing → Budgets & alerts. $20 with alerts at 50/90/100% matches what this repo assumes.

---

## Part 5: two identities, one gcloud

You now have two Google accounts that both talk to GCP, and exactly one `gcloud` install.
Named configurations keep them apart. This is also squarely on the ACE exam.

- [ ] **5.1** Create a configuration for the lab:
      ```bash
      gcloud config configurations create lab
      gcloud config configurations activate lab
      gcloud auth login admin@yourdomain.dev
      gcloud auth application-default login
      ```

- [ ] **5.2** Confirm your original setup is untouched:
      ```bash
      gcloud config configurations list
      ```
      You should see `default` and `lab`, with exactly one `IS_ACTIVE: True`.

- [ ] **5.3** Learn the switch, because you will need it constantly:
      ```bash
      gcloud config configurations activate lab       # lab org
      gcloud config configurations activate default   # everything else
      ```

> **The trap:** Application Default Credentials are **global**, not per-configuration. Running
> `gcloud auth application-default login` overwrites ADC for every configuration, and Terraform
> uses ADC. So switching configurations changes what `gcloud` does but **not necessarily what
> Terraform does**. `scripts/auth.sh` checks that the two agree and refuses to proceed when they
> do not. This is the most dangerous inconsistency in a two-org setup, because nothing on
> screen tells you it is happening.

---

## Part 6: point the repo at it

- [ ] **6.1** Use a separate checkout, or at minimum a separate `config.env`. Two orgs sharing
      one config file is how you apply the lab's org policies to the wrong place.

- [ ] **6.2** Fill in `config.env`:
      ```bash
      TF_VAR_org_id=<lab org numeric id>
      TF_VAR_billing_account=<your existing billing account>
      TF_VAR_customer_id=<from: gcloud organizations list --format="value(owner.directoryCustomerId)">
      TF_VAR_prefix=<3-10 lowercase chars, globally unique>
      GCLOUD_CONFIGURATION=lab

      # Unlocks organization-node writes for this org and no other.
      ORG_WRITES_ALLOWED_FOR=<the same lab org numeric id>

      # Nothing in the lab org to protect, but keep the real ones listed anyway. It costs
      # nothing, and this file gets copied between machines.
      PROTECTED_IDS="<your prod project ids>"
      ```

- [ ] **6.3** Verify before building anything:
      ```bash
      make auth
      make preflight
      ```
      Preflight fails if `ORG_WRITES_ALLOWED_FOR` disagrees with `TF_VAR_org_id`, if ADC is
      authenticated as a different identity than the active configuration, or if any required
      role is missing.

- [ ] **6.4** Confirm the guard understands the new mode:
      ```bash
      make guard-test
      ```
      Org-mode fixtures prove that unlocking this org does not unlock any other.

- [ ] **6.5** Build:
      ```bash
      make bootstrap
      make up
      make apply STACK=1-org      # the org-level stage, only runs in an unlocked org
      ```

---

## Verification

You are done when all of these are true:

- [ ] `gcloud organizations list` shows **two** organizations from your normal account, or one
      from each configuration
- [ ] `gcloud config configurations list` shows `default` and `lab`
- [ ] `make preflight` passes with the `lab` configuration active
- [ ] `make guard-test` passes 23/23
- [ ] Switching to `default` and running `make preflight` fails on the org mismatch. That is
      the safety property working, not a problem
- [ ] A budget alert exists on the lab org

---

## If it goes wrong

**Verification will not complete.** The TXT record is at the apex (`@`), not `www`, and there is
no trailing whitespace. `dig +short TXT yourdomain.dev` should show it. DNS propagation is the
usual cause; wait an hour before assuming anything is broken.

**The domain was absorbed into your existing tenant.** You used the wrong signup flow. Remove
the secondary domain from the existing Cloud Identity account, wait for it to release, and sign
up fresh. Annoying but recoverable.

**You cannot create folders despite being Organization Administrator.** Part 3.4. Org Admin
manages IAM; it does not itself grant the ability to create resources.

**Terraform 403s while gcloud works fine.** ADC is stale or belongs to the other identity. This
is the global-ADC trap from Part 5. Run `make auth`.

**You want to undo the whole thing.** Delete the projects, delete the folders, then cancel the
Cloud Identity account from its admin console. The organization is removed with the account.
The domain stays yours until it expires.
