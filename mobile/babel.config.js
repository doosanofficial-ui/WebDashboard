module.exports = {
  presets: ["module:@react-native/babel-preset"],
  env: {
    test: {
      presets: [["@babel/preset-env", { targets: { node: "current" } }]],
    },
  },
};
