import {
	bytesToHex,
	ConsensusAggregationByFields,
	cre,
	getNetwork,
	median,
	TxStatus,
	type HTTPSendRequester,
	type Runtime,
} from '@chainlink/cre-sdk'
import { type Address, encodeAbiParameters, parseAbiParameters } from 'viem'
import { z } from 'zod'
import {
	TemperatureConsumer,
	type DecodedLog,
	type TemperatureRequestedDecoded,
} from '../contracts/evm/ts/generated/TemperatureConsumer'

// ─── Config Schema ──────────────────────────────────────────
export const configSchema = z.object({
	chainSelectorName: z.string(),
	consumerAddress: z.string(),
	gasLimit: z.string().optional(),
})
type Config = z.infer<typeof configSchema>

const GEOCODE_URL = 'https://geocoding-api.open-meteo.com/v1/search'
const FORECAST_URL = 'https://api.open-meteo.com/v1/forecast'

type Reading = {
	temperatureC: number
	observedAt: number
}

/**
 * Runs inside the DON's BFT consensus layer: every node performs both HTTP calls
 * independently and ConsensusAggregationByFields reconciles the numbers.
 *
 * Only numeric fields are returned. The city string comes from the trigger log,
 * which is identical on every node, so no string consensus is needed — and the
 * non-ASCII canonical names Open-Meteo returns (e.g. "São Paulo") never reach
 * the report.
 */
export const fetchTemperature = (
	sendRequester: HTTPSendRequester,
	config: { city: string },
): Reading => {
	// 1. Geocode the city name to coordinates.
	const geoResponse = sendRequester
		.sendRequest({
			url: `${GEOCODE_URL}?name=${encodeURIComponent(config.city)}&count=1`,
			method: 'GET',
		})
		.result()

	if (geoResponse.statusCode !== 200) {
		throw new Error(`Geocoding returned HTTP ${geoResponse.statusCode}`)
	}

	const geoBody = JSON.parse(Buffer.from(geoResponse.body).toString('utf-8'))
	const place = geoBody.results?.[0]
	if (!place) {
		throw new Error(`City not found: ${config.city}`)
	}

	// 2. Fetch the current temperature for those coordinates.
	const wxResponse = sendRequester
		.sendRequest({
			url: `${FORECAST_URL}?latitude=${place.latitude}&longitude=${place.longitude}&current=temperature_2m&timezone=UTC`,
			method: 'GET',
		})
		.result()

	if (wxResponse.statusCode !== 200) {
		throw new Error(`Forecast returned HTTP ${wxResponse.statusCode}`)
	}

	const wxBody = JSON.parse(Buffer.from(wxResponse.body).toString('utf-8'))
	const current = wxBody.current
	if (!current || typeof current.temperature_2m !== 'number') {
		throw new Error('Forecast response missing current.temperature_2m')
	}

	// Open-Meteo buckets readings into 15-minute intervals (interval: 900), so
	// nodes querying the same window agree. Rounding adds margin at boundaries.
	return {
		temperatureC: Math.round(current.temperature_2m),
		observedAt: Math.floor(Date.parse(`${current.time}Z`) / 1000),
	}
}

// ─── Log Trigger Callback ───────────────────────────────────
export const onTemperatureRequested = (
	runtime: Runtime<Config>,
	payload: DecodedLog<TemperatureRequestedDecoded>,
): string => {
	const { requestId, city } = payload.data
	runtime.log(`TemperatureRequested: city="${city}" requestId=${requestId}`)

	// 1. Fetch, with per-field DON consensus.
	const httpClient = new cre.capabilities.HTTPClient()
	const reading = httpClient
		.sendRequest(
			runtime,
			fetchTemperature,
			ConsensusAggregationByFields<Reading>({
				temperatureC: median,
				observedAt: median,
			}),
		)({ city })
		.result()

	runtime.log(`Consensus reading: ${reading.temperatureC}C at ${reading.observedAt}`)

	// 2. Encode the report. Flat ABI parameters — a struct would add a leading
	//    offset word and fail TemperatureConsumer._processReport's abi.decode.
	const reportData = encodeAbiParameters(
		parseAbiParameters(
			'bytes32 requestId, string city, int32 temperatureC, uint32 observedAt',
		),
		[requestId, city, reading.temperatureC, reading.observedAt],
	)

	// 3. Submit the signed report. The Forwarder verifies signatures, then calls
	//    onReport() on the consumer.
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: runtime.config.chainSelectorName,
		isTestnet: true,
	})
	if (!network) {
		throw new Error(`Network not found: ${runtime.config.chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)
	const consumer = new TemperatureConsumer(
		evmClient,
		runtime.config.consumerAddress as Address,
	)

	const writeResult = consumer.writeReport(runtime, reportData, {
		gasLimit: runtime.config.gasLimit,
	})

	if (writeResult.txStatus !== TxStatus.SUCCESS) {
		throw new Error(
			`Report write failed: ${writeResult.errorMessage || writeResult.txStatus}`,
		)
	}

	const txHash = bytesToHex(writeResult.txHash || new Uint8Array(32))
	runtime.log(`Temperature written onchain! TX: ${txHash}`)

	return `${city}: ${reading.temperatureC}C — tx: ${txHash}`
}

// ─── Workflow Init ──────────────────────────────────────────
export function initWorkflow(config: Config) {
	const network = getNetwork({
		chainFamily: 'evm',
		chainSelectorName: config.chainSelectorName,
		isTestnet: true,
	})
	if (!network) {
		throw new Error(`Network not found: ${config.chainSelectorName}`)
	}

	const evmClient = new cre.capabilities.EVMClient(network.chainSelector.selector)
	const consumer = new TemperatureConsumer(
		evmClient,
		config.consumerAddress as Address,
	)

	return [
		cre.handler(consumer.logTriggerTemperatureRequested(), onTemperatureRequested),
	]
}
