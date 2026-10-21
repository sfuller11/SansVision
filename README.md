# Plant Pals

React + Vite front end, Supabase for accounts and per-user plant data.

## Run it on your computer
1. Install Node.js (the LTS version) from nodejs.org.
2. Create a free project at supabase.com. In **SQL Editor > New query**, paste all of `supabase/schema.sql` and click **Run**.
3. In Supabase go to **Project Settings > API**. Copy the Project URL and the anon (or "publishable") key.
   Never use the `service_role` / secret key in this app.
4. Copy `.env.example` to `.env` and paste in those two values.
5. In this folder run `npm install`, then `npm run dev`, and open the address it prints.
6. Sign up. Supabase emails a confirmation link by default. For quick testing you can turn it off under
   **Authentication > Sign In / Providers > Email**.
7. To make yourself admin, run the commented `update public.profiles ...` line at the bottom of `schema.sql`
   in the SQL Editor, with your email.

## Put it online (Vercel, free)
1. Create a GitHub account and push this folder to a new repository (`.env` is already git-ignored).
2. At vercel.com, choose **Add New > Project** and import the repository. It detects Vite on its own.
3. Under **Environment Variables**, add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` with the same values as your `.env`.
4. Click **Deploy**. You get a public `https://your-app.vercel.app` address.
5. Back in Supabase, open **Authentication > URL Configuration**. Set **Site URL** to your Vercel address
   and add it under Redirect URLs, so email confirmation links go to the live site.

Netlify works the same way: build command `npm run build`, publish directory `dist`.

## How it works
- Each plant is a row in `plants` with a `last_watered_at` time. The app works out how thirsty it is from that time.
- Row Level Security makes sure users only see and change their own plants.
- A database trigger stops non-admins from changing growth stage, so admin mode can't be faked from the browser.

## Updating an app you already deployed
1. Run `supabase/migration_002_new_plants.sql` in the Supabase SQL Editor.
2. Replace your project files with the new ones, then `git add .`, `git commit -m "New plants"`, `git push`. Vercel redeploys on its own.

## Increment 1 (foundation): how to apply
Order for a fresh database: `schema.sql`, then `migration_002_new_plants.sql`, then `migration_003_foundation.sql`.
If you already ran the first two, run only `migration_003_foundation.sql` in the Supabase SQL Editor, then replace the project files, push to GitHub, and Vercel redeploys.
Then run `supabase/tests/increment1_tests.sql` in the SQL Editor. It rolls itself back and prints "All Increment 1 tests passed".
All coins, growth, watering and ownership now change only through database functions, never directly from the browser.
Plants come from the admin "Grant" button for now; discovery arrives in Increment 2.

## Increment 2 (discovery): how to apply
1. Run `supabase/migration_004_discovery.sql` in the SQL Editor (after migration_003). Watering now completes the daily care task, so "Tend" is gone.
2. Replace the project files, push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment1_tests.sql` again (updated for the new care rule), then `supabase/tests/increment2_tests.sql`.
4. Costs, odds, duplicate rewards and Rhizome prices live in the `discovery` row of the `game_config` table. Edit them there; a tier with odds that do not add up to 100 is refused.
Not covered by the SQL tests: two requests at the same instant. Check by opening the site in two tabs and clicking Discover in both with exactly 50 coins. Only one should succeed.

## Increment 3 (achievements): how to apply
1. Run `supabase/migration_005_achievements.sql` in the SQL Editor (after migration_004).
2. Replace the project files, push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment3_tests.sql`. The earlier test files still apply (run increment2 again with the fixed version).
Achievements and their rewards live in the `achievements` table, so you can edit amounts or targets there.
Dedicated Collector (15 plants) and Botanical Library (25 plants) show "unlocks when more plants are added" until the catalog is big enough.
The three garden achievements are switched off until the gardens increment.

## Increment 4 (gardens and Realm): how to apply
1. Run `supabase/migration_006_gardens.sql` in the SQL Editor (after migration_005). It also adds the 8 new plants.
2. Replace the project files (the new plant pictures are in `public/plants`), push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment4_tests.sql`.
The Rooms screen is now "My Garden": garden name, description, publish/unpublish, and per-plant "Show to visitors".
Realm lists public gardens (12 per page, "Load more"), has a random garden button, and opens gardens read-only.
Visitors are recorded once per garden, never for your own garden. This is what the three garden achievements count.

## Migration 7 (inventory, XP, backgrounds): how to apply
1. Run `supabase/migration_007_inventory_themes.sql` in the SQL Editor (after migration_006).
2. Replace the project files (the redrawn plant pictures are in `public/plants`), push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment2_tests.sql` again (updated for duplicates), then `supabase/tests/increment7_tests.sql`.
Duplicates are now inventory items. Costs of backgrounds live in the `garden_themes` table. The Double XP length and strength are in the `discovery` row of `game_config` (`double_xp_hours`, `double_xp_multiplier`).

## Migration 8 (progression): how to apply
1. Run `supabase/migration_008_progression.sql` in the SQL Editor (after migration_007). Run it only once: it multiplies existing growth by each plant's rarity so progress is kept under the longer timings.
2. Replace the project files, push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment8_tests.sql`. Re-run increment 2, 3 and 7 as well: their expected numbers were updated for the new duplicate Rhizome values and rarity timings.
What it adds: rarity growth multipliers (common 1x to legendary 2.5x), 2x/5x boosts bought with Leaf Coins or Rhizomes, gem stage skips, player level and XP, the level badge, level-up pop-up, the "while you were away" pop-up, and rarity-coloured plant names.
All values (multipliers, boost prices, skip gem costs, XP amounts, level rewards, away threshold in minutes) are rows in `game_config`: `growth`, `boosts`, `skip_gems`, `xp`, `levels`, `away`.
Tall plants (20 sizes) skip to the start of the next growth phase, and pay XP once per phase, so they match 5-stage plants.

## Migration 9 (mini-games and Shop): how to apply
1. Run `supabase/migration_009_minigames.sql` in the SQL Editor (after migration_008).
2. Replace the project files (this zip also has the latest Dark Pink Bat and Coppertone pictures in `public/plants`), push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment9_tests.sql`.
Games: Leaf Match (3 per hour, 15 per day), Rhizome Rush (5 per hour, 20 per day), Garden Cleanup (2 per hour, 10 per day), Growth Burst Spinner (1 per 4 hours, 6 per day). The Mini-Games tab shows plays left and the daily streak (3 games = +50 coins +1 rhizome). Seven days in a row also pays +150 coins +3 rhizomes +1 gem. Five perfect Rhizome Rush rounds in a row pay +50 coins +1 rhizome.
Limits, streak rewards and the session length are in the `games` row of `game_config`. The prize tables for each game are inside the `finish_game` and `spin` functions.
Honest limit: Leaf Match misses and Rhizome Rush hits come from the browser, so someone technical could fake a perfect score. Rewards stay capped by the hourly and daily limits, Garden Cleanup is timed by the server, and the spinner is rolled by the server.
The Shop tab is display only: no purchase can happen yet.

## Migration 10 (profile, Collection, Odd Plant Out, avatars): how to apply
1. Run `supabase/migration_010_profile_collection.sql` in the SQL Editor (after migration_009). It also creates the `avatars` storage bucket and its rules, so nothing needs to be set up by hand in Storage.
2. Replace the project files (new pictures are in `public/leaves` and `public/icons`), push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment10_tests.sql`, then `increment9_tests.sql` (updated for Odd Plant Out).
What changed:
- Tap your name (top left) to open the profile window: Profile (picture, display name, level, stats), Achievements and Collection. Achievements is no longer a main tab. A red dot on your name means a reward is ready or you have a new plant.
- Collection lists every plant by rarity. Plants you do not own are silhouettes with no name; open one to see the odds and the Rhizome price to unlock it. Opened plants show their stage gallery, when and how you got them, and a Fully grown badge.
- Odd Plant Out replaces Garden Cleanup (10 rounds, grid grows from 3x3 to 5x5, each wrong tap adds 2 seconds). Leaf Match now uses leaf pictures. Rhizome Rush has a 5x5 grid, faster sprouts, and 7 catches earn the top prize.
- Profile pictures are cropped square, shrunk to 256 px and saved as a JPEG in the browser, then stored in the `avatars` bucket (one file per player, 256 KB limit). They show on your profile and to visitors of your public garden.

## Migration 11 (garden scenes, new plants, likes, Realm sorting): how to apply
1. Run `supabase/migration_011_gardens_scenes.sql` in the SQL Editor (after migration_010). Run it only once.
2. Replace the project files (new pictures: `public/gardens` has the 8 garden pictures; `public/plants` has 7 new plants plus the redrawn Gabriella and Dark Pink Bat), push to GitHub, and Vercel redeploys.
3. Run `supabase/tests/increment11_tests.sql`. The garden parts of the older increment 1, 4 and 7 tests describe the removed four-room house, so skip those; everything else still applies.
What changed:
- The four-room house is gone. Each player can own several gardens (one of each type). Every garden is a picture with named spots, and plants stand on those spots. Three skins (Night Greenhouse, Autumn Backyard, Desert Canyon) reuse the layout of their base garden.
- Gardens and prices (table `garden_types`, change them there): Greenhouse (free, 10 spots), Balcony (250 coins, 7), Night Greenhouse (300 coins, 10), Backyard (500 coins, 10), Autumn Backyard (6 gems, 10), Rock Garden (900 coins, 10), Desert Canyon (8 gems, 10), Zen Courtyard (12 gems, 12).
- Spots have a size (small, medium, large) in `garden_spots`. Tall plants such as Banded Nelsonii cannot use small spots. Spot positions on the picture are in `src/gardenLayouts.js`; the ids there must match `garden_spots`.
- My Garden: switch between your gardens, tap a plant then a spot to place it, publish each garden separately, buy new ones in the Garden shop. A plant can only stand in one garden at a time.
- Existing players: their garden becomes a Greenhouse and up to 10 placed plants move onto its spots (oldest first); the rest return to "Not placed". Garden backgrounds bought in migration 7 are refunded once, because they no longer exist.
- New plants: Golden Flame, Halli Bat and Masoniana (common), Silver Bat (uncommon), Blue Bat (rare), Kirkii Coral Blue Variegated and Bhitalli Silver Blue Variegated (legendary). Rarities are only the `rarity` column in `plant_catalog`, so you can change them there. Discovery picks from every active plant of the rolled rarity, so each new plant now shares its tier's odds.
- Likes: players can like other players' public gardens (not their own), once each. Press again to remove it. Counts are stored on the garden.
- Realm: sort by Recently published, Most liked or Highest level (the owner's level). Pages are 12 at a time with Load more. A garden shows in the Realm only if something on it is marked "Show to visitors".
Honest limits: likes are one per account, so someone could make extra accounts to inflate a garden. The Realm sorts are computed on each request, which is fine for hundreds of gardens, not hundreds of thousands.

## Migration 12: hub, landing page, three new games

Run `supabase/migration_012_hub_games.sql` after migration 11, push the app, then run `supabase/tests/increment12_tests.sql`.

- **One-click remove**: every placed plant in My Garden has a small x. The "Show to visitors" box is gone. Visitors see every plant on a spot, and a garden with nothing placed is not listed in the Realm. Plants that were placed but hidden are unplaced by the migration.
- **Spinner**: 3 spins a day, one every 8 hours. Prizes: 100 to 200 coins (some with 1 or 2 Rhizomes), 5 Rhizomes, or 1 Gem. The server rolls the prize.
- **New games**: Water Balance, Vine Climb, Garden Snake. The server decides the prize. The browser reports one number (rounds landed, drops caught, sprouts eaten), which is capped by the real elapsed time. A determined player could still report a high number within that cap.
- **Home tab**: away summary card, today's checklist, game streak, spinner status, featured garden, next goal. There is no "Needs you" section.
- **Featured garden**: a public garden with at least one plant. Other players' gardens come first, then the most likes in the last 7 days, then a pick that is stable for the UTC day.
- **Arcade** is the old Mini-Games tab. **Plants** is the old Garden tab.
- **Landing page** for signed-out visitors: sample garden, growth stages, all 8 gardens, rarities, games, and sign-up.
- **Mobile controls**: swipe on the Garden Snake board or tap the on-screen pad; Vine Climb uses drag or hold-to-steer arrows. WASD and arrow keys work on desktop.
