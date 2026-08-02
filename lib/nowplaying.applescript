-- Reports the currently playing track, without ever launching a music app.
-- Output: "<app>\t<title>\t<artist>\t<album>\t<genre>"  (empty line if nothing plays)
--
-- Spotify does not expose a genre field over AppleScript; Apple Music does,
-- so the genre slot is filled only for Music and left blank for Spotify.

on run
	set spotifyUp to false
	set musicUp to false
	try
		tell application "System Events"
			set spotifyUp to (exists process "Spotify")
			set musicUp to (exists process "Music")
		end tell
	on error
		return ""
	end try

	if spotifyUp then
		try
			tell application "Spotify"
				if player state is playing then
					set t to name of current track
					set a to artist of current track
					set al to album of current track
					return "spotify" & tab & t & tab & a & tab & al & tab & ""
				end if
			end tell
		end try
	end if

	if musicUp then
		try
			tell application "Music"
				if player state is playing then
					set t to name of current track
					set a to artist of current track
					set al to album of current track
					set g to ""
					try
						set g to genre of current track
					end try
					return "music" & tab & t & tab & a & tab & al & tab & g
				end if
			end tell
		end try
	end if

	return ""
end run
