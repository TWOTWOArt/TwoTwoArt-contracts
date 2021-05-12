const BEP20 = artifacts.require("./BEP20.sol");

module.exports = function (deployer) {
  deployer.deploy(BEP20);
};
