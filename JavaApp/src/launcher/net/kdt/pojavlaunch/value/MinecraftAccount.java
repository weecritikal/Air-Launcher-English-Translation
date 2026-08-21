package net.kdt.pojavlaunch.value;
import net.kdt.pojavlaunch.*;
import java.io.*;
import com.google.gson.*;

public class MinecraftAccount
{
    public String accessToken = "0"; // access token
    public String clientToken = "0"; // clientID: refresh and invalidate
    public String profileId = "00000000-0000-0000-0000-000000000000"; // authenticate UUID
    public String username = "Steve";
    public String xuid;
    // The unique account identifier: xuid for Microsoft accounts, profileId for third-party accounts, a UUID for local accounts
    // It matches BaseAuthenticator.authData[@"accountId"] on the native side and is used as the account file name
    public String accountId = "";

    public String save(String outPath) throws IOException {
        Tools.write(outPath, Tools.GLOBAL_GSON.toJson(this));
        return outPath;
    }

    public String save() throws IOException {
        // The file name uses the accountId (the unique identifier), so accounts with the same name no longer collide
        String id = (accountId != null && !accountId.isEmpty()) ? accountId : username;
        return save(Tools.DIR_ACCOUNT_NEW + "/" + id + ".json");
    }

    public static MinecraftAccount parse(String content) throws JsonSyntaxException {
        MinecraftAccount account = Tools.GLOBAL_GSON.fromJson(content, MinecraftAccount.class);
        // Read access token from keychain
        if (account.xuid != null) {
            account.accessToken = getAccessTokenFromKeychain(account.xuid);
        }
        return account;
    }

    public static MinecraftAccount load(String name) throws IOException, JsonSyntaxException {
        // name is the accountId (passed in as args[0] by launchJVM on the native side) and is used as the account file name
        MinecraftAccount acc = parse(Tools.read(Tools.DIR_ACCOUNT_NEW + "/" + name + ".json"));
        if (acc.accessToken == null) {
            acc.accessToken = "0";
        } if (acc.clientToken == null) {
            acc.clientToken = "0";
        } if (acc.profileId == null) {
            acc.profileId = "0";
        } if (acc.username == null) {
            acc.username = "0";
        } if (acc.xuid == null) {
            acc.xuid = "0";
        }
        // accountId fallback: prefer the name argument (the accountId passed in by the native side), then xuid, then profileId
        if (acc.accountId == null || acc.accountId.isEmpty()) {
            acc.accountId = name;
        }
        return acc;
    }

    static {
        System.loadLibrary("FluxAccountJNI");
    }
    public static native String getAccessTokenFromKeychain(String xuid);
}
