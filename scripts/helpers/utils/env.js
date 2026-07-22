const fs = require("fs");

const { CONFIG_STATE, ENV_STATE } = require("../shared/states");

const updateEnv = (...args) => {
    // Returning if running on the local network.
    if (CONFIG_STATE.environment === "hardhat" || CONFIG_STATE.environment === "localhost") {
        return;
    }

    let variables = {};
    let filePathIndex;

    // Parsing arguments.
    const [firstArgument] = args;

    if (typeof firstArgument === "string") {
        // Processing for a key-value pair, if the first parameter is a string.
        variables[firstArgument] = args[1];
        filePathIndex = 2;
    } else if (firstArgument && typeof firstArgument === "object") {
        // Using directly, if the first parameter is an object.
        variables = firstArgument;
        filePathIndex = 1;
    } else {
        throw new Error("Invalid arguments");
    }

    const filePath = args[filePathIndex] || ".env";

    // Loading env if not previously saved to shared state.
    if (!ENV_STATE[filePath]) {
        // Getting env.
        const env = fs.readFileSync(filePath, "utf8");

        // Saving env to shared state.
        ENV_STATE[filePath] = env;
    }

    // Parsing env.
    const lines = ENV_STATE[filePath].split("\n");
    const keys = Object.keys(variables);
    const allKeys = new Set();

    // Updating environment variables where applicable.
    env = "";

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const trimmedLine = line.trim();

        if (trimmedLine && !trimmedLine.startsWith("#") && trimmedLine.includes("=")) {
            const [currentKey] = trimmedLine.split("=");

            if (keys.includes(currentKey)) {
                env += `${currentKey}=${variables[currentKey]}`;

                allKeys.add(currentKey);
            } else {
                env += line;
            }
        } else {
            env += line;
        }

        if (i < lines.length - 1) {
            env += "\n";
        }
    }

    // Adding a trailing Newline if missing.
    if (!env.endsWith("\n")) {
        env += "\n";
    }

    // Adding new environment variables where applicable.
    keys.forEach((key) => {
        if (!allKeys.has(key)) {
            env += "\n";
            env += `${key}=${variables[key]}`;

            if (key === keys[keys.length - 1]) {
                env += "\n";
            }
        }
    });

    // Saving env to shared state.
    ENV_STATE[filePath] = env;

    // Saving env to file.
    fs.writeFileSync(filePath, env);
};

module.exports = {
    updateEnv
};
