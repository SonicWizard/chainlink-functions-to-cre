// Code generated — DO NOT EDIT.
import type { Address } from 'viem'
import { addContractMock, type ContractMock, type EvmMock } from '@chainlink/cre-sdk/test'

import { TemperatureConsumerABI } from './TemperatureConsumer'

export type TemperatureConsumerMock = {
  getExpectedAuthor?: () => `0x${string}`
  getExpectedWorkflowId?: () => `0x${string}`
  getExpectedWorkflowName?: () => `0x${string}`
  getForwarderAddress?: () => `0x${string}`
  owner?: () => `0x${string}`
  sLastCity?: () => string
  sLastObservedAt?: () => number
  sLastRequestId?: () => `0x${string}`
  sLastTemperatureC?: () => number
  sRequestedCity?: (requestId: `0x${string}`) => string
  supportsInterface?: (interfaceId: `0x${string}`) => boolean
} & Pick<ContractMock<typeof TemperatureConsumerABI>, 'writeReport'>

export function newTemperatureConsumerMock(address: Address, evmMock: EvmMock): TemperatureConsumerMock {
  return addContractMock(evmMock, { address, abi: TemperatureConsumerABI }) as TemperatureConsumerMock
}

