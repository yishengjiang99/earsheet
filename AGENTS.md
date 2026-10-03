# Agent rules: token efficiency (applies to every agent in this repo)

You are an expert efficiency optimizer operating as Agent MD. Your primary objective is to execute tasks with maximum accuracy while minimizing token consumption. Adhere strictly to the following execution rules to conserve both input and output tokens:

1. **Strict Output Conciseness**
   * Provide direct answers first. Eliminate conversational filler, introductory preambles, and polite concluding remarks.
   * Use ultra-short, dense sentences. Rely on fragments or bullet points where grammatically acceptable.
   * Avoid repeating context, rules, or data provided in the user's prompt.
2. **Aggressive Context Pruning**
   * Prioritize relevant data. Extract only the lines needed for the next step.
3. **No Redundant Text**
   * Do not explain how you arrived at an answer unless explicitly asked.
   * If generating code, provide only the modified segments or diffs rather than reprinting the entire file.
4. **Token-Efficient Formatting**
   * Prefer standard markdown lists over heavy visual syntax.

App identity is locked in docs/asc/APP_IDENTITY.md (AI Music Radar, com.ragnus.pnge, ASC app 6818838017). Do not change it without the owner.

## ASC / signing secrets

Repo Actions secrets (same values as omr-sheet-cam, finalcut, photo-recipes; set 2026-10-03). Never print, log or paste values.

| Secret | Source |
|---|---|
| `APP_STORE_CONNECT_KEY_ID` | Key `95M27GJTV7`; key file on the shared box `/workspace/asc/AuthKey_95M27GJTV7.p8` |
| `APP_STORE_CONNECT_ISSUER_ID` | GitHub secret on omr-sheet-cam (no plaintext copy on the box) |
| `APP_STORE_CONNECT_API_KEY_P8` | `/workspace/asc/AuthKey_95M27GJTV7.p8`, also box env `ASC_API_PRIVATE_KEY` |
| `IOS_DISTRIBUTION_P12_BASE64` | Apple Distribution cert `YXDKHJC7J9` (team `83D36RPMUM`); only in GitHub secrets on omr-sheet-cam/finalcut/photo-recipes |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Same: GitHub secrets only |
| `IOS_APPSTORE_PROFILE_PNGE_BASE64` | Optional, not set. `ios-testflight.yml` reuses or creates the `com.ragnus.pnge` App Store profile via the ASC API |

### How they were copied (secret-to-secret, no plaintext leaves GitHub)
1. Target repo public key: `gh api repos/yishengjiang99/<target>/actions/secrets/public-key` (gives `key_id`, `key`).
2. In omr-sheet-cam, push a temporary `workflow_dispatch` workflow to main (`[skip ci]`) with input `target_key`. It maps each secret into env and seals it with PyNaCl (`public.SealedBox(PublicKey(target_key, Base64Encoder)).encrypt(value)`). It writes `{NAME: base64(ciphertext)}` to `sealed.json` and uploads that as an artifact with `retention-days: 1`. Only GitHub can decrypt it.
3. `gh workflow run tmp-secret-xfer.yml -R yishengjiang99/omr-sheet-cam --ref main -f target_key=<key>`, then `gh run watch <id> --exit-status`.
4. `gh run download <id> -R yishengjiang99/omr-sheet-cam -n sealed -D $(mktemp -d)`, then for each entry:
   `gh api -X PUT repos/yishengjiang99/<target>/actions/secrets/<NAME> -f encrypted_value=<blob> -f key_id=<key_id> --silent`.
5. Clean up right away: `gh api -X DELETE repos/yishengjiang99/omr-sheet-cam/actions/artifacts/<artifact_id>`, `git rm` the temp workflow and push (`[skip ci]`), `gh run delete <id>`, delete the local `sealed.json`.
6. Check: `gh secret list -R yishengjiang99/<target>`.

For a new repo, repeat steps 1–6 with the new target. Add a per-bundle profile secret only if that repo's workflow needs one.
