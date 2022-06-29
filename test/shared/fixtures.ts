import { ethers } from "hardhat";

async function deployContract(name: string, args: Array<any>) {
  const contractFactory = await ethers.getContractFactory(name);
  return await contractFactory.deploy(...args);
}

async function contractAt(name: string, address: string) {
  const contractFactory = await ethers.getContractFactory(name);
  return await contractFactory.attach(address);
}

export { deployContract, contractAt };
