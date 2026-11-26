# Changelog

## iPhone 0.1.53

### Bugs/Polish

- Toy Box now needs iOS 27.2 or later.

## iPhone 0.1.52

### Bugs/Polish

- Tapping right after you swipe through Vim or less now works the first time, so you can bring up the keyboard without waiting for the text to stop moving.

## Mac 0.1.55

### Bugs/Polish

- The terminal stays out of your way. While it connects you see only a small spinner where you type, coming back after a while gives you a fresh prompt with everything you'd run still above it, and opening the same shell somewhere else no longer ends it here, where a click takes it back.
- Typing `exit` now closes the terminal, and opening it again starts a fresh shell, so you're never left looking at one that has ended.

## iPhone 0.1.51

### Bugs/Polish

- The terminal stays out of your way. While it connects you see only a small spinner where you type, coming back after a while gives you a fresh prompt with everything you'd run still above it, and opening the same shell somewhere else no longer ends it on your phone, where a tap takes it back.
- Swiping now scrolls inside full-screen programs like Vim, less and htop, so you can read a long file or log with your thumb.
- Typing `exit` now closes the terminal, and opening it again starts a fresh shell, so you're never left looking at one that has ended.

## Mac 0.1.54

### Features

- You can now open a terminal on any of your servers right from Toy Box, and it keeps running while you work in other windows, so you can start a long command and check back on it without leaving the app.

### Bugs/Polish

- A server's status in Settings now reads in one word, like Connected or Reconnecting…, without error text that flashes when a connection briefly drops, and checking for updates shows each new version without an extra note telling you to restart.

## iPhone 0.1.50

### Features

- You can now open a terminal on your server right from your phone, and pick up the same shell when you come back to it, so you can run a quick command or check on a long one without going back to your Mac.

### Bugs/Polish

- Opening a channel with new messages takes you straight to them again, without bouncing or briefly showing the top of the conversation first.
- After you open a request or bookmark near the end of a conversation, new messages keep coming into view, instead of arriving out of sight below it.
- Each server's status in Settings now reads in one word, like Connected or Reconnecting…, without error text that flashes when a connection briefly drops, and checking for updates shows each new version without an extra note telling you to restart.

## Mac 0.1.53

### Bugs/Polish

- The Servers tab in Settings now offers Check for Updates for every server's model providers, where some servers were missing it, so you can keep your agents on the latest from any of them.
- The Servers tab in Settings is easier to read at a glance, with each server's name, address, status and version together under Server Details, and Disconnect Servers… always beside the server list.

## iPhone 0.1.49

### Bugs/Polish

- Each server's page in Settings now offers Check for Updates for its model providers, where some servers were missing it, so you can keep your agents on the latest from any of them.
- Each server's page in Settings is easier to read at a glance, with its name, address, status and version together in one card, and Settings' General section now holds Appearance and the app's version.

## iPhone 0.1.48

### Features

- You can now check each model provider on your server from its page in Settings, with its version, your plan and how much of each usage limit you've used, so you know before an agent runs out.
- You can now update your server's model providers from its page in Settings, then restart the server from the same place to start using the new versions, so your agents always run the latest.

### Bugs/Polish

- Coming back to Toy Box and opening a conversation now shows it right away, keeping the messages you already had on screen while it reconnects and then starting from the first new one, instead of sometimes leaving a blank screen until you scrolled.
- Settings now opens with your servers and Disconnect, then notifications and on-device intelligence, so what you reach for most comes first.
- While you search a conversation, new messages no longer move it under you, and closing the search picks back up wherever you were reading or following along.

## Mac 0.1.52

### Features

- You can now check each model provider on your server from the Servers tab in Settings, with its version, your plan and how much of each usage limit you've used, so you know before an agent runs out.
- You can now update your server's model providers from the Servers tab in Settings, then restart the server from the same place to start using the new versions, so your agents always run the latest.

### Bugs/Polish

- Switching to a channel with a few new messages that don't fit on screen now opens on the first of them instead of skipping to the end, so you never miss what arrived while you were away.
- With Your Messages on, scrolling to the top now keeps loading older history even past a stretch with none of your messages, so you can always reach the beginning of a conversation.

## iPhone 0.1.47

### Bugs/Polish

- Picking someone from the @ list now works with a tap, a scroll or Return, so mentioning an agent no longer misses or lands on the conversation behind it.
- On a narrow screen or at large text sizes, the composer now keeps who you're writing to and Input Needed on the same line as Send instead of stacking them, leaving more room for your message and the conversation.
- Opening a conversation now always shows its latest messages, never a blank screen or a view stopped partway up, even right after typing in another channel.

## Mac 0.1.51

### Features

- When an agent's request includes screenshots or files, you can now see them right in the request and open them with a click, so you know what it's asking about before you answer.

## iPhone 0.1.46

### Features

- When an agent's request includes screenshots or files, you can now see them right on its card and open them with a tap, so you know what it's asking about before you answer.

## Mac 0.1.50

### Features

- When an agent's message links to a file it shared, clicking the link now opens the file right in the channel, so you can read what they're pointing at without hunting for it.

### Bugs/Polish

- The preview link in a channel's Overview now shows the pointing hand when you hover it, so you can tell it opens, like links in messages.

## iPhone 0.1.45

### Features

- When an agent's message links to a file it shared, tapping the link now opens the file right in the channel, so you can read what they're pointing at without hunting for it.

### Bugs/Polish

- Scrolling up through a long conversation now flows straight into older messages, without pausing at the top while they load.

## Mac 0.1.49

### Features

- When an agent is waiting on a command, like a build or a CI run, you can now see it and the command itself, so you know it'll pick back up the moment the command finishes.

### Bugs/Polish

- Artifacts in a channel on another of your servers now open, instead of showing a "not found" error, and Open in Toy Box takes you to that channel on its own server.
- Quick Send now shows the channel's icon next to its name, so you can tell at a glance where your message is going.
- Jumping to a message that Message View is hiding now switches back to all messages and takes you to it, instead of getting stuck loading.

## iPhone 0.1.44

### Features

- When an agent is waiting on a command, like a build or a CI run, you can now see it and the command itself, so you know it'll pick back up the moment the command finishes.

### Bugs/Polish

- Open in Toy Box now works for artifacts in a channel on another of your servers, so you can jump straight to it in your browser.
- Scrolling up through a conversation now always loads older messages, even after a quick flick to the top, instead of sometimes stopping until you touch the screen again.

## Mac 0.1.48

### Bugs/Polish

- While you're following the latest messages, dragging the window's edge now keeps them in view the whole time, instead of the conversation flashing far up as you drag.

## Mac 0.1.47

### Bugs/Polish

- Dragging the window's edge to resize it while you're reading now keeps the message you were reading right where it was, so you never lose your place.

## Mac 0.1.46

### Bugs/Polish

- Sending to a channel you have open, from Quick Send, the menu bar or a notification, now brings you to your message even if you'd scrolled up, just like sending from the channel itself.
- Hovering a change to the channel, like a new routine or a changed preview, now shows who made it and its full details, such as the routine's prompt or the preview's whole link.
- A channel where one agent wrote a long run of messages while you were away now opens on the first one you haven't read, instead of opening blank, and revealing any message in that run brings it right up.
- Creating a channel no longer asks for a folder on the server. The lead sets one up when the work needs it, so starting a channel takes just a name and what you want done. The channel and agent sheets also look tidier, with their titles and buttons evenly spaced.

## iPhone 0.1.43

### Bugs/Polish

- A new or changed routine's details now include its prompt, so you can see what it will do without leaving the conversation.

## Mac 0.1.45

### Bugs/Polish

- Clicking the mic now opens the talk card right away, with no pause while the microphone gets ready.
- Replying to a request from the sidebar now lines your words up with the send button, so the field looks right whether you've typed one line or several.
- A channel now stays read while you look at one of its images or artifacts, so messages that arrive meanwhile don't leave it unread in the sidebar.
- Clicking a link in a message now always opens it, even while your pointer is over the message to select its text.
- Revealing a message, from a bookmark, a notification or Find, now brings it up near the top where you start reading, and always takes you there.
- A channel that's entirely new to you now opens at its latest message, so you start where the conversation is.

## Mac 0.1.44

### Bugs/Polish

- A long request in the sidebar now stays a comfortable size and scrolls, instead of stretching to fill the screen.
- A channel you're looking at now stays read as new messages arrive, wherever you've scrolled, so it no longer shows up as unread in the sidebar while you're in it.
- Coming back to a channel after you've been in another window or app now moves New to what arrived while you were away, so you can see at a glance what you missed.
- When you talk to the Lead, Send is ready as soon as your words appear, so you can send the moment you finish speaking.
- When you send or cancel a note to the Lead, the card now settles back into its row smoothly, with no flash as its text returns to the sidebar, just a check to show your note went, and your open channel stays highlighted.

## iPhone 0.1.42

### Bugs/Polish

- Swiping a team member, artifact, routine or bookmark now shows simple round buttons, matching your channel list.
- Images in a channel now show as soon as you open it, even ones that arrived while you were away, instead of staying blank.
- Relaunching Toy Box now brings you back to where you left off: the channel you were reading, or your list of channels if you'd gone back to it.
- A channel you're in now always stays read, including when you reopen it, come back to the app or open something on top of it, so it never shows as unread when you go back to your channels.
- Revealing a message, from a bookmark, a notification or Find, now brings it up near the top where you start reading, and always takes you there.
- Going back into a channel now always shows its conversation, instead of sometimes opening blank.

## iPhone 0.1.41

### Bugs/Polish

- A long request's card now stays compact and scrolls, so the rest of your channels stay in view.
- Sitting in a channel now keeps it read as new messages arrive, so it no longer shows up as unread when you go back to your channels.
- Coming back to the app on a channel now moves New to what arrived while you were away, so you can see at a glance what you missed.
- Opening a channel at New now keeps up with the conversation, so a message that arrives a moment later comes into view instead of staying below.
- Scrolling back through older messages now keeps your place as they load, instead of jumping you far ahead.
- When you talk to the Lead, Send is ready as soon as your words appear, so you can send the moment you finish speaking.
- After you send a note to the Lead, the card settles back into its row as smoothly as Cancel, with just a check to show it went.

## Mac 0.1.43

### Bugs/Polish

- Opening a channel now always shows its newest message in full, even when a picture in it finishes loading a moment later, and Jump to Latest no longer flickers on as the channel opens.

## Mac 0.1.42

### Bugs/Polish

- Pressing Send while dictation is still getting ready sends what you typed and leaves the microphone off, instead of it starting to listen in your next message.
- Closing Bookmarks before it finishes finding an older message no longer leaves the conversation stuck on "Couldn't load older messages", so scrolling back keeps loading earlier history.
- When a channel opens with a summary of what you missed, the New divider stays where it first appears instead of jumping up a moment later, so you start reading in the right place.
- A task that's waiting on you now shows you as its owner instead of "Deleted agent", so you can see at a glance what's yours to do.
- The New divider no longer appears above a message you just sent, so it only ever marks what others wrote that you haven't read.
- Opening a channel where you left off shows the conversation right away, instead of a blank moment while it finds your place.

## iPhone 0.1.40

### Bugs/Polish

- Flicking past new messages and then scrolling back no longer marks them read, because a channel now counts as read only up to where you stop scrolling.
- Sending a message while dictation downloads your language for the first time no longer cancels the download, so dictation is ready the next time you tap it.
- Closing Bookmarks before it finishes finding an older message no longer stops the conversation from loading earlier history as you scroll back.
- A task that's waiting on you now shows you as its owner instead of "Deleted agent", so you can see at a glance what's yours to do.
- Coming back to Toy Box no longer leaves a conversation blank until you scroll, so you always see where you left off.
- The New divider no longer appears above a message you just sent, so it only ever marks what others wrote that you haven't read.
- Tapping anywhere on a channel that's waiting on you opens its request, including the blank space in its row, so it's easy to hit with your thumb.

## Mac 0.1.41

### Features

- When your Macs have an update waiting, one Restart in Settings brings them all onto it. Each one shows the version it's moving to, and none drops out of your list while it restarts.
- Answer a channel that's waiting on you right from the sidebar, without leaving the channel you're in. Rest on it or click its bubble to see the question, then reply or pick a choice.
- Talk to any channel's Lead right from the sidebar, without leaving the channel you're in. Say what you want, watch your words appear, and send them as a message.

### Bugs/Polish

- The menu bar and Quick Send show each channel's icon, and Quick Send shows the folder each channel works in instead of its purpose, so you can spot the one you want at a glance.
- Windows you leave open now come back where you left them when Toy Box restarts or updates, on the same channel or screens. One showing another of your Macs fills in as soon as that Mac answers.
- A reply you send from anywhere, like the web, a notification or another device, marks its channel read everywhere at once, once your Macs run Toy Box 0.4.5.
- Videos in a conversation start playing right away instead of waiting to download, and a file shows what kind it is and opens in Quick Look with a click.
- Deleting a channel, removing an agent or deleting a routine now asks in a standard Mac alert, so the choice that can't be undone is clearly marked.

## iPhone 0.1.39

### Features

- When your Macs have an update waiting, one Restart in Settings brings them all onto it. Each one shows the version it's moving to, and none drops out of your list while it restarts.

### Bugs/Polish

- A channel waiting on you stays a calm row in your list that shows its question, and opens to answer only when you tap it, so a new request never takes over the screen.
- A reply you send from anywhere, like the web, a notification or another device, marks its channel read everywhere at once, once your Macs run Toy Box 0.4.5.
- On iPhone Duo unfolded, a channel you've read stays read when you move to another, instead of showing as unread again.
- On iPhone Duo unfolded in portrait, the channel list gets out of the way when you open a channel, so you see it right away. In landscape, the list stays beside the conversation.

## Mac 0.1.40

### Features

- Connect to any one of your Macs and Toy Box finds the rest on its own, so there's nothing to link or add one by one. A Mac that's asleep drops out of the list and comes back when it wakes.
- The first time you open Toy Box, you can connect right from the sidebar, without a trip to Settings.
- Disconnect in Settings forgets your servers, so you can start fresh by connecting to any one of your Macs.

### Bugs/Polish

- When an address can't work, like one with a password in it, Toy Box tells you exactly what to change.

## iPhone 0.1.38

### Features

- Connect to any one of your Macs and Toy Box finds the rest on its own, so there's nothing to link or add one by one. A Mac that's asleep drops out of the list and comes back when it wakes.
- Setting up is one step now: enter your Mac's address and tap Connect.
- Disconnect in Settings forgets your servers, so you can start fresh by connecting to any one of your Macs.

## iPhone 0.1.37

### Features

- Tap Edit in the channel list to clear out old channels quickly. Delete removes a channel right away, without asking a second time.

### Bugs/Polish

- On iPhone Duo, unfolding your phone keeps Overview and the channel list just as you left them, and Overview's button now always closes it on the first tap.
- On iPhone Duo, the unfolded channel list no longer squeezes a cut-off Toy Box title into its top bar.

## Mac 0.1.39

### Bugs/Polish

- Playing a video in a conversation no longer closes Toy Box, and WebM videos now play too.

## iPhone 0.1.36

### Bugs/Polish

- WebM videos in a conversation now play.
- The channel list's Toy Box title now stays small at the top, leaving more room for your channels.

## Mac 0.1.38

### Features

- You can now restart any of your servers from Settings whenever you like, not just after an update, so a server that's acting up is one tap from a fresh start.

### Bugs/Polish

- When Toy Box can't list a server's screens, it now says so plainly in the middle of the window, with Try Again right there.
- A new channel now tells you its lead is getting it ready, right in the middle of the conversation, so you know work has started before the first message arrives.

## iPhone 0.1.35

### Features

- You can now restart any of your servers from Settings whenever you like, not just after an update, so a server that's acting up is one tap from a fresh start.

### Bugs/Polish

- When Toy Box can't list a server's screens, it now says so plainly in the middle of the window, with Try Again right there.
- A new channel now tells you its lead is getting it ready, right in the middle of the conversation, so you know work has started before the first message arrives.

## Mac 0.1.37

### Features

- You can now add a server by just its name, like your Tailscale machine name, without typing `https://`.
- You can now remove all of your servers, and Toy Box goes back to how it looked the first time, ready for you to add one.

### Bugs/Polish

- The channel list now always shows your server's name, even when you have just one, so it's clear whose channels you're looking at.
- When servers can't link, Settings now says so in one plain line with Try Again, instead of an error only a developer could read.
- While your channels load, the list's placeholders now look like your channels, from their avatars to their times.

## iPhone 0.1.34

### Features

- You can now add a server by just its name, like your Tailscale machine name, without typing `https://`.
- You can now remove all of your servers, and Toy Box goes back to how it looked the first time, ready for you to add one.

### Bugs/Polish

- The channel list now always shows your server's name, even when you have just one, so it's clear whose channels you're looking at.
- When servers can't link, Settings now says so in one plain line with Try Again, instead of an error only a developer could read.
- While your channels load, the list's placeholders now look like your channels, from their avatars to their times.

## Mac 0.1.36

This version needs Toy Box 0.4.0 or later on each of your servers. If you added a server by a `.local` name or a short name like `mac-mini`, add it again by its full Tailscale name or IP address.

### Features

- You can now name each of your servers in Settings, and the name stays with the server, so every Mac and iPhone you use calls it the same thing.
- Adding a server now adds the servers it's linked with too, so one address brings in all of your servers.
- Adding a server you already have at a new address, like its Tailscale address, now moves it there instead of listing it twice, and keeps your drafts and unsent messages.

## iPhone 0.1.33

This version needs Toy Box 0.4.0 or later on each of your servers. If you added a server by a `.local` name or a short name like `mac-mini`, add it again by its full Tailscale name or IP address.

### Features

- You can now name each of your servers in Settings, and the name stays with the server, so every Mac and iPhone you use calls it the same thing.
- Adding a server now adds the servers it's linked with too, so one address brings in all of your servers.
- Adding a server you already have at a new address, like its Tailscale address, now moves it there instead of listing it twice, and keeps your drafts and unsent messages.

## Mac 0.1.35

### Features

- You can now link your Toy Box servers from Settings, so a channel's lead on one server can see the channels on your others and ask them for work.

## iPhone 0.1.32

### Features

- You can now link your Toy Box servers from Settings, so a channel's lead on one server can see the channels on your others and ask them for work.

### Bugs/Polish

- When you talk to a channel or answer a request from the list, the mic and the check now keep the shape of the channel's picture, so the row reads as one piece.

## Mac 0.1.34

### Features

- Each channel now shows its own picture or icon, so you can tell your channels apart at a glance, and the conversation shows when it gets a new one.
- You can now keep your Toy Box servers up to date from Settings. Check for Updates installs the latest release on every server at once, and Restart moves a server onto it right from its row.

### Bugs/Polish

- A server that stops answering no longer fills the sidebar with an error. Its status dot changes color, and hovering over it tells you what went wrong. With several servers, only a server with a problem shows a dot by its name, so a healthy sidebar stays quiet.
- A server's name in the sidebar no longer keeps spinning after the server has connected.
- Typing @ and a name suggests just the agents with that name, instead of everyone whose role happens to mention it.
- Opening a channel shows its conversation right away, instead of sometimes leaving it blank while agents are working or a request waits for you.
- Typing a message keeps up with every key, even while agents are working or your Mac is busy.
- An image that can't load no longer fills the conversation with its file path and an error. It keeps its place, and clicking it tries again.
- When your server turns something down, like a name that's already taken, its message now reads just as the server wrote it, without a technical code tacked on.

## iPhone 0.1.31

### Features

- Each channel now shows its own picture or icon, so you can tell your channels apart at a glance, and the conversation shows when it gets a new one.
- You can now keep your Toy Box servers up to date from Settings. Check for Updates installs the latest release on every server at once, and Restart moves a server onto it right from its row.

### Bugs/Polish

- A server that stops answering no longer fills the channel list with an error. With several servers, only a server with a problem shows a dot by its name, and tapping it shows what went wrong, with Server Settings one tap away.
- Scrolling the channel list with a request open no longer freezes the app, even with several servers.
- Opening a long channel no longer freezes the app while the conversation settles at your place.
- Typing @ and a name suggests just the agents with that name, instead of everyone whose role happens to mention it.
- Opening a channel with a request waiting for you no longer sometimes leaves its conversation blank.
- Typing a message keeps up with every key, even while agents are working.
- An image that can't load keeps its place in the conversation, and tapping it tries again.
- When your server turns something down, like a name that's already taken, its message now reads just as the server wrote it, without a technical code tacked on.

## Mac 0.1.33

### Bugs/Polish

- A screen you control looks just as it does when you watch it, with no frame around it, and the Take Control button alone tells you you're in control.

## iPhone 0.1.30

### Bugs/Polish

- Bringing up the keyboard on a screen you control leaves the screen right where it was, so you never lose your place, and a two-finger drag lifts anything the keyboard covers into view.
- A screen you control looks just as it does when you watch it, with no frame around it, and the Take Control button alone tells you you're in control.

## Mac 0.1.32

### Features

- You can now take control of a screen from its viewer, and your mouse, scrolling and typing go straight to it until you release control or switch away.

### Bugs/Polish

- Server names in the sidebar are easier to read, in the same gray as the status line below them.

## iPhone 0.1.29

### Features

- You can now take control of a screen from your phone, and tap, drag and type on it as if you were sitting at it.

### Bugs/Polish

- Turning your phone while you look at a screen keeps it zoomed in on what you were looking at.

## iPhone 0.1.28

### Bugs/Polish

- With several servers, each one's name shows how many channels it has, and collapsing a server no longer hides a request waiting for you there.
- The Screens title now lets you refresh the list, switch to another server or add one, all in one place, and it names the server only when you have more than one.

## Mac 0.1.31

### Bugs/Polish

- Your servers now have their own tab in Settings, and with several servers the bottom of the sidebar tells you at a glance whether any of them is having trouble and takes you straight to that tab.
- Collapsing a server in the sidebar no longer hides a request waiting for you there, and the server names have a little more room to breathe.
- The Screens window's title now lets you refresh the list, switch to another server or add one, all in one place, and it names the server only when you have more than one.
- Toy Box no longer quits unexpectedly when a change to a channel can't be saved while VoiceOver or another app that reads the screen is running.

## iPhone 0.1.27

### Features

- You can now connect to several Toy Box servers at once, like one at home and one at work. The channel list shows each server's channels under its name, and notifications, Lock Screen replies, the icon badge, the Needs You widget, Live Activities, Share and Siri cover all of them, so nothing waiting for you is missed.

### Bugs/Polish

- Unfolding an iPhone Duo with a channel open keeps the channel full width, and unfolding from the channel list keeps the list showing, so you carry on where you were.
- Toy Box no longer freezes when you open Overview with your phone folded and turned sideways.

## Mac 0.1.30

### Features

- You can now connect to several Toy Box servers at once, like one at home and one at work. The sidebar shows each server's channels under its name, Quick Send, Siri and Spotlight reach every channel on any of them, and notifications, the menu bar, the Dock, the Needs You widget and the morning digest cover all of them, so nothing waiting for you is missed.

### Bugs/Polish

- Toy Box no longer quits unexpectedly when you switch channels while VoiceOver or another app that reads the screen is running.
- When Toy Box can't reach your server, the sidebar now simply says so, without buttons to press, since it keeps trying on its own and clicking your server's address still opens Settings.

## Mac 0.1.29

### Bugs/Polish

- A channel no longer warns that your read position wasn't saved, since Toy Box saves your place again the next time you read.
- An artifact's menu in Overview is shorter and clearer, starting with Open Artifact, and Space still previews it with Quick Look.
- The buttons around the message box now light up as your pointer passes over them, the same way as everywhere else in the app, so it's clear what you're about to click.

## iPhone 0.1.26

### Bugs/Polish

- Works with Toy Box 0.3.8, which sends simpler responses, so update Toy Box along with this version.
- On the folded iPhone, a request in the channel list no longer shows cut off on its right side when it arrives just as you open a channel.
- Swiping a channel in the list now shows just the Talk and Delete icons, without titles underneath, for a cleaner look.
- Closing Find now lowers the keyboard right away, instead of a moment after the message box comes back.
- Ready for an upcoming Toy Box update that makes the channel list lighter to download.
- Notifications and the Needs You widget show a waiting request's question sooner and use less data, since it now comes with the channel list.
- While the channel list reconnects, a quieter notice now says your channels may be out of date, and tapping it tries again right away.
- While a channel reconnects, the message box no longer gains empty space above your text.
- An image you send now stays on screen when Toy Box confirms it, instead of briefly blanking while it downloads again.

## Mac 0.1.28

### Bugs/Polish

- Works with Toy Box 0.3.8, which sends simpler responses, so update Toy Box along with this version.
- Ready for an upcoming Toy Box update that makes the channel list lighter to download.
- Notifications and the menu bar show a waiting request's question sooner and use less data, since it now comes with the channel list.
- A finished task list's notification now simply says all tasks are completed, since it marks the whole list being done rather than one task.
- An image you send now stays on screen when Toy Box confirms it, instead of briefly blanking while it downloads again.

## iPhone 0.1.25

### Bugs/Polish

- A request in the channel list now opens with its question already showing, instead of a placeholder that fills in a moment later.
- After you reply from the channel list, that channel no longer flashes unread for your own message.
- Finishing a voice note in the channel list no longer makes that channel's time flicker, so the list stays calm as your note goes out.

## Mac 0.1.27

### Bugs/Polish

- After you send from Quick Send, the menu bar or a notification, that channel no longer flashes unread for your own message.

## Mac 0.1.26

### Features

- A request waiting for you can now be read aloud, so you can hear it while you do something else.
- Sending from Quick Send, the menu bar or a notification is now instant, and if your connection drops or your server is asleep, Toy Box sends your message as soon as it can, so nothing you send gets lost.

### Bugs/Polish

- If a message can't be sent, it now stays in its channel so you can retry it or delete it.
- Replying to a notification now marks that channel read, so it doesn't stay unread after you've answered.

## iPhone 0.1.24

### Features

- A request waiting for you can now be read aloud, so you can hear it while you do something else, even with your phone locked.
- Replying from the Lock Screen or the channel list is now instant, and if your connection drops or your server is asleep, Toy Box sends your message as soon as it can, so nothing you send gets lost.

### Bugs/Polish

- If a message can't be sent, it now stays in its channel so you can retry it or delete it.
- Replying from the Lock Screen now marks that channel read, so it doesn't stay unread after you've answered.
- Sharing to a channel while your server is asleep no longer leaves the share sheet waiting, and Toy Box sends it once the server is back.
- A reply you type in the channel list while you're offline now stays put until you're back, instead of failing.
- After you send your own reply to a request in the channel list, the card settles straight back into its row, so it's clear where your answer went.
- A channel's name and time now hold still as its request opens and closes in the channel list, and when its agents start or stop working, so the list never flickers.

## iPhone 0.1.23

### Bugs/Polish

- Opening a request in the channel list no longer shifts its time over, and the request reads cleaner, so it feels like the same row growing to show the question.
- A request opened in the channel list now reads exactly as it does in the conversation, with its formatting, lists and code intact.
- Opening a long request from the channel list now lands on it, instead of leaving the conversation blank.
- A channel's name now floats over the conversation as a glass button that opens its actions, and messages fade softly beneath it instead of stopping at a hard bar.

## iPhone 0.1.22

### Features

- When a channel needs you, the channel list shows its question, and you can answer it right there with a suggested reply or your own words, without opening the channel.

### Bugs/Polish

- Long suggested replies that wrap now read like ordinary text, which makes them easier to scan.

## Mac 0.1.25

### Bugs/Polish

- Long suggested replies that wrap now read like ordinary text, in the conversation and the menu bar, which makes them easier to scan.
- The bookmark button on a message works again after the app opens or reconnects to its server, instead of ignoring the pointer.

## iPhone 0.1.21

### Bugs/Polish

- Swiping a channel in the list keeps it inside the list, instead of sliding under the controls beside it on a folded Duo.
- Going back to the channel list on a folded Duo shows the line under the channel you left right away.
- Talking to a channel near the bottom of the list keeps the recorder on its row, and it grows upward only as your words need the room.

## iPhone 0.1.20

### Bugs/Polish

- Talking to a channel from the list looks smoother, since the lines between rows stay clear of the recorder and are already back as it closes.

## iPhone 0.1.19

### Bugs/Polish

- On an unfolded phone, Overview opens at its narrowest width, leaving more room for the conversation.
- While you talk to a channel from the list, the lines around its row stay out of the way, and they come back as soon as you're done.

## Mac 0.1.24

### Features

- When the window is wide, the tray above the composer shows the three newest artifacts instead of one, so recent work is a click away. The tray also has a little more room around it.

### Bugs/Polish

- The toolbar that appears when you hover over a message is lighter and roomier, so it's easier to read and click.

## iPhone 0.1.18

### Features

- Swipe a channel right in the list to talk to its Lead without opening it, and your words are sent as a note while you stay where you are.

### Bugs/Polish

- A zoomed screen now stays where you pinch and pan it, and pinching stops at the zoom limit instead of springing back.
- With an iPhone Duo unfolded, the channel list's search field now reads Search in full instead of being cut off.

## iPhone 0.1.17

### Features

- Bookmark any message and jump back to it later from the bookmarks button above the composer, so important decisions and requests are easy to find again.

### Bugs/Polish

- With an iPhone Duo unfolded, the channel list now highlights the channel you have open, so you can always see where you are.

## Mac 0.1.23

### Features

- Siri can now answer questions about the channel or Markdown file in front of you, so you can ask what's left to do or what the team decided without reading back through the conversation.
- Bookmark any message and jump back to it later from the bookmarks list above the composer, so important decisions and requests are easy to find again.

### Bugs/Polish

- New messages arrive more smoothly while the pointer rests over the conversation.

## iPhone 0.1.16

### Features

- Siri can now answer questions about the channel or Markdown file you have open, so you can ask what's left to do or what the team decided without reading back through the conversation.

### Bugs/Polish

- Screens now zoom in as far as image attachments do, so pinching in to read small text no longer springs back.

## Mac 0.1.22

### Features

- The Screens window has a Refresh button, so you can pick up new windows and fresh thumbnails without reopening it.

### Bugs/Polish

- An open file or image now keeps every action in a menu on its name, with its most useful action, Reload or Copy, right beside Share.
- Turning on Message View now just tints its button, so it stays easy to spot without changing shape.

## iPhone 0.1.15

### Bugs/Polish

- Pulling to refresh the Screens list now also refreshes every thumbnail, so each one shows how its screen looks right now.
- Zooming and panning a screen now stays smooth every time, and the screen holds your zoom and place as it updates.

## Mac 0.1.21

### Features

- When a channel's preview is a window or display on the Mac running Toy Box, you can now watch it live in the app, and browse everything that Mac can show.

### Bugs/Polish

- The window's toolbar is simpler and lets the conversation run to the top. The channel's actions now open from its name, and Overview runs the full height of the window.
- An open file shows its name beside Back, with nothing between the toolbar and the file.

## iPhone 0.1.14

### Features

- When a channel's preview is a window or display on the Mac running Toy Box, you can now watch it live in the app, and browse everything that Mac can show.

### Bugs/Polish

- Deleting a channel, agent or routine now asks once in a simple alert, right where you are, instead of opening a sheet first.
- Opening a channel from a notification or the widget now closes Settings first, so the channel is right there.

## iPhone 0.1.13

### Features

- Opening the working capsule now also shows who's waiting and what for, so coming back to a channel tells you where everyone stands.

### Bugs/Polish

- The channel bar is simpler. Tasks are in Overview, and Find, Follow, Edit and the rest open from the channel's name.
- Markdown files are easier to read, with text sized like messages, flowing paragraphs and clearer section headings.

## Mac 0.1.20

### Features

- Opening the working capsule now also shows who's waiting and what for, so coming back to a channel tells you where everyone stands.

### Bugs/Polish

- Markdown files are easier to read, with text sized like messages, flowing paragraphs and clearer section headings.

## iPhone 0.1.12

### Features

- The team list can now be filtered to only the agents who are working, which makes it easier to see who's busy.
- Tapping a channel's name now opens its actions, so Find, Follow, Edit and the rest stay one tap away even while you're typing.

### Bugs/Polish

- Overview's team section is now called Team Members.
- The channel list now updates the moment anything changes, so new requests and replies show up right away.

## Mac 0.1.19

### Features

- The team list can now be filtered to only the agents who are working, which makes it easier to see who's busy.

### Bugs/Polish

- Overview's team section is now called Team Members.
- The channel list now updates the moment anything changes, so new requests and replies show up right away.

## iPhone 0.1.11

### Bugs/Polish

- The task filter is easier to find, and easier to tell when it's on.
- Overview's section headers line up more cleanly.

## Mac 0.1.18

### Bugs/Polish

- The task filter is easier to find, and easier to tell when it's on.

## iPhone 0.1.10

### Features

- The task list can now be filtered to only in-progress items, which makes it easier to track progress.
- The task list now opens with finished and waiting work folded away, so what's moving stands out.
- Artifacts can be removed with a single swipe, which makes tidying up a channel quicker.

### Bugs/Polish

- It's easier to tell when the transcript is showing only your messages.
- Channel and agent sheets look and feel like the rest of iOS.
- The Settings icon is cleaner.
- Day and New dividers in the transcript are evenly spaced.

## Mac 0.1.17

### Features

- The task list can now be filtered to only in-progress items, which makes it easier to track progress.
- The task list now opens with finished and waiting work folded away, so what's moving stands out.

### Bugs/Polish

- Day and New dividers in the transcript are evenly spaced.

## iPhone 0.1.9

- See a request's suggested replies and Reply as small buttons at their natural widths, matching the Mac, instead of full-width blue buttons.
- See day labels on the leading edge with a line after them, like the Mac and web. When the day and New meet, they share one line.
- See a little less space under each day label.

## Mac 0.1.16

- See a line after each day label, like the web. When the day and New meet, they share one line instead of stacking.

## iPhone 0.1.8

- Answer a request with one tap. Its suggested replies show inside the request, and tapping one sends it at once.
- Press and hold a request notification to send one of its suggested replies from the Lock Screen, or type your own with Reply.
- Remove an artifact from a channel in Overview. Its file stays where it is.
- See one line when someone shares or removes several artifacts in a row.
- Tap an artifact's title where it was shared or removed to open it. Press and hold the line for its details.
- See a request's header wrap at the largest text sizes, so the request stays clear of the toolbar.
- Reply puts just the author's mention in the composer, and the separate Mention action is gone.
- See why Follow This Channel is unavailable, right in its menu.
- Keep typing while a message sends, and see it drawn exactly as it will look once sent.
- Open a message from a notification while its channel catches up, without an unavailable error.

## Mac 0.1.15

- Answer a request with one click. Its suggested replies show inside the request, in the menu bar inbox and on its notification, and choosing one sends it at once.
- Remove an artifact from a channel in Overview. Its file stays where it is.
- See one line when someone shares or removes several artifacts in a row.
- Open a removed artifact from its title in the conversation, like a shared one.
- Reply puts just the author's mention in the composer with the caret after it, and the separate Mention action is gone.
- Keep typing while a message sends, and see it drawn exactly as it will look once sent.
- Open a message from a notification while its channel catches up, without an unavailable error.

## iPhone 0.1.7

- Share a screenshot, photo or link to a channel from the share sheet, with a note, without opening Toy Box. Channels you share to show up as suggestions.
- See "Reconnecting to server" when a channel loses its connection. It reconnects on its own, so there's no Retry button.
- Reconnect as soon as your network comes back or moves between Wi-Fi and cellular.
- Keep seeing Connecting while a large channel loads over a slow connection, instead of Can't Connect.
- See Overview without a separate reconnecting note.
- See Welcome's Continue button float over the screen without a band behind it.
- See routines in Overview with a calendar icon, like artifacts. Tap one to read its prompt, swipe right to run it now or left to delete it, or press and hold for both.
- Open SVG artifacts in Overview much faster after the first one.
- Reopen a channel that moved on and see it caught up at once, without its messages, team and tasks replaying what you missed.

## Mac 0.1.14

- See "Reconnecting to server" float over the conversation when a channel loses its connection, without moving any messages. It reconnects on its own, so there's no Retry button.
- Reconnect as soon as your network comes back or changes, or when you switch back to Toy Box.
- Keep seeing Connecting while a large channel loads over a slow connection, instead of Can't Connect.
- See Overview without a separate reconnecting note, and Quick Send without a Retry button while a channel reconnects.
- Expand a routine in Overview to read just its prompt, without the next run date or raw schedule. Hover the schedule for its cron expression.
- Find a notification reply that didn't send waiting in its channel with Send Again, which can never post it twice.
- Reopen a channel that moved on and land straight on New or the latest message, without scrolling through what you missed or watching the team and tasks replay it.

## iPhone 0.1.6

- Tap a team member in Overview to see their role, status and model, in a popover beside the conversation when unfolded or a sheet sized to fit when folded.
- See icons beside All Messages and Your Messages in the Message View menu.

## Mac 0.1.13

- See the Toy Box robot in the menu bar, with a badge when a channel needs your reply and dots while agents work.
- Read requests under Needs Your Reply in the menu bar inbox. Long requests scroll in place, so you can read all of one while you reply.
- Choose All Messages or Your Messages straight from the toolbar's filter button, with icons that match the View menu.
- See an agent's status and model use the About popover's full width.

## iPhone 0.1.5

- Connect from a simpler Welcome screen: enter your server, test it, then Continue.
- Switch servers in Settings as soon as a test of the new address connects.
- Find Message View first in a channel's overflow menu.
- Open Tasks from the toolbar, now that the tray above the composer is gone.
- Pull down to refresh the channel list, which now waits until you let go, without a Refresh button or More menu.
- Keep Overview open when you rotate or fold the phone. It sits beside the conversation in unfolded landscape and opens as a sheet otherwise.
- Keep messages marked read when you leave a channel right away.
- See the Find bar sit just above the keyboard.
- Open SVG artifacts in Overview faster.
- Use the system overflow menu and a cleaner page bar in the image gallery.
- See Settings and setup server rows at the standard row height, and evenly spaced team rows in Overview at every text size.

## Mac 0.1.12

- See Working Now rows in the menu bar inbox line up with your requests, without a separate heading.
- Choose a channel in Quick Send from a native list that works with the arrow keys, Return and a click anywhere in a row.
- Keep messages marked read when you close a channel right away.

## iPhone 0.1.4

- See the New divider above your first unread message when you reopen a channel, instead of landing at the end with everything marked read.
- Read the conversation behind the floating composer, pills and Find bar.
- See who you're writing to in a clearer To badge, beside a white mic.
- Type in a roomier Find field.
- Scan tighter team rows in Overview.
- Close sheets with a plain close button.
- See Use Server in Settings only when you've typed a different, valid address.
- Add an agent with a labeled Name row, a question about its role and an Add button, matching New Channel.

## Mac 0.1.11

- See the New divider above your first unread message when you reopen a channel.

## iPhone 0.1.3

- Find in a conversation from the bottom of the screen, where the search bar takes the composer's place until you close it.
- See the composer, mention list, pills and notices in the same plain glass as the toolbar.
- Close Overview with the system close button, and copy the channel folder from its own row.
- See one connection notice with Retry when a server or channel is unavailable, and no notice for a quick reconnect.
- Keep live updates through Control Center and the app switcher, pausing them only in the background.
- Reach the newest message with one tap of Jump to Latest, even mid-scroll.
- Stay at the newest message when you fold or unfold the phone.
- Open Overview beside the conversation in landscape without the transcript re-wrapping.
- Keep the app badge accurate while the app is open.

## Mac 0.1.10

- See one connection notice with Retry when a server or channel is unavailable, and no notice for a quick reconnect.
- Refresh the channel list with ⌘R, while Retry on the notice reconnects the channel.
- Watch Send turn into a spinner while its channel connects.
- Read Show More and Show Less as quiet secondary text.
- See images you've already viewed right away, without reloading them.

## iPhone 0.1.2

- Find the widget as Toy Box in the gallery. Its rows show the channel name, request text and time, without a repeated requester name or avatar.
- Receive the channel name and question directly in each push, without waiting for the phone to reach your server.
- Keep the app badge in sync with channels waiting for your reply, including replies sent from another device.

## Mac 0.1.9

- Keep waiting requests in view with a quieter Toy Box widget, showing the channel name, request text and time without a repeated requester name or avatar.
- Continue the same channel between your Mac and iPhone with Handoff.
- Lead with the channel name and question in request alerts, and open the original message from the alert.
- Choose request and completion notifications in Settings. Requests default on and completions default off, without changing saved preferences.
- Keep a message's attachments together in one sideways-scrolling row.
- Search a conversation in one compact Find bar, with progress and errors in the same row.
- Read task timing, nested tasks and agent check-in countdowns more clearly in Overview.
- Fit Markdown tables to their columns, with scrolling for wide tables and clean rounded borders.

## iPhone 0.1.1

- Live Activities use the Toy Box logo on the Lock Screen and in the Dynamic Island.
- Show channel and message details in notifications from HTTP servers, including Tailscale hosts.
- Lead with the channel name and question in alerts, without a repeated requester name or avatar.
- Retry a failed notification setup when the app becomes active again.
- Hide notification options while notifications are off. Requests default on and completions default off, without changing saved preferences.

## iPhone 0.1.0

- First iPhone companion for Toy Box channel conversations, replies and shared work.
- Notification replies, the Needs You widget, Handoff with the Mac and following a channel in a Live Activity.
