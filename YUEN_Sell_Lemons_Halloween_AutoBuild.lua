-- YUEN Halloween Diagnostic — read-only
local Workspace = game:GetService("Workspace")

local prompts = 0
local matches = 0

print("===== YUEN HALLOWEEN DIAGNOSTIC =====")

for _, obj in ipairs(Workspace:GetDescendants()) do
    if obj:IsA("ProximityPrompt") then
        prompts += 1

        local action = tostring(obj.ActionText)
        local object = tostring(obj.ObjectText)
        local parent = obj.Parent and obj.Parent:GetFullName() or "No parent"

        local text = (action .. " " .. object .. " " .. parent):lower()

        if text:find("candy")
            or text:find("coin")
            or text:find("pumpkin")
            or text:find("spooky")
            or text:find("halloween")
            or text:find("buy")
            or text:find("upgrade") then

            matches += 1
            print(
                "[MATCH]", action,
                "| Object:", object,
                "| Enabled:", obj.Enabled,
                "| Parent:", parent
            )
        end
    end
end

print("Total ProximityPrompts:", prompts)
print("Possible event matches:", matches)
print("===== DIAGNOSTIC COMPLETE =====")
