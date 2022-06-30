import { MockProvider } from "ethereum-waffle";

export async function send(
    provider: MockProvider,
    method: string,
    params: Array<any> = []
) {
    await provider.send(method, params);
}

export async function mineBlock(provider: MockProvider): Promise<void> {
    await send(provider, "evm_mine");
}

export async function increaseTime(provider: MockProvider, seconds: any) {
    await send(provider, "evm_increaseTime", [seconds]);
}
