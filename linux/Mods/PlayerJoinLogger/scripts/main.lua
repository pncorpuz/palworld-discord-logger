-- PlayerJoinLogger: prints a console line whenever a player joins the server.
-- Confirmed against CXXHeaderDump/Engine.hpp: APlayerController::ServerAcknowledgePossession(APawn* P)
-- Confirmed against CXXHeaderDump/Pal.hpp: APalPlayerState : public APlayerState, has GetPlayerName() (inherited)
--
-- Note: hook params (including the "self" context) come in as RemoteUnrealParam
-- and must be unwrapped with :get() before you can read properties off them.

local function OnServerAcknowledgePossession(self, P)
    local pawn = P and P:get()
    local playerState = pawn and pawn.PlayerState

    if playerState then
        local playerName = playerState:GetPlayerName():ToString()
        print(string.format("[PlayerJoinLogger] Player joined: %s\n", playerName))
    else
        print("[PlayerJoinLogger] Player joined (could not resolve PlayerState)\n")
    end
end

RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", OnServerAcknowledgePossession)

print("[PlayerJoinLogger] Mod loaded.\n")
