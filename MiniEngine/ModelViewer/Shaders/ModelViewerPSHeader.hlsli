//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
// Developed by Minigraph
//
// Author(s):	James Stanard
//				Alex Nankervis
//
// Thanks to Michal Drobot for his feedback.

// Modified 2018, Intel Corporation
// This is now an implementation file which is called by
// a ModelEviewerPS_* shader which sets the appropriate #defines

#include "ModelViewerRS.hlsli"
#include "LightGrid.hlsli"

// outdated warning about for-loop variable scope
#pragma warning (disable: 3078)
// single-iteration loop
#pragma warning (disable: 3557)

#define ENABLE_LIGHT_GRID

#ifdef SAMPLE_SHADING
struct VSOutput
{
    sample float4 position : SV_Position;
    sample float3 worldPos : WorldPos;
    sample float2 uv : TexCoord0;
    sample float3 viewDir : TexCoord1;
    sample float3 shadowCoord : TexCoord2;
    sample float3 normal : Normal;
    sample float3 tangent : Tangent;
    sample float3 bitangent : Bitangent;
    uint sampleIndex : SV_SampleIndex;
};
#endif

#ifdef CENTROID_SHADING
struct VSOutput
{
	centroid float4 position : SV_Position;
	centroid float3 worldPos : WorldPos;
	centroid float2 uv : TexCoord0;
	centroid float3 viewDir : TexCoord1;
	centroid float3 shadowCoord : TexCoord2;
	centroid float3 normal : Normal;
	centroid float3 tangent : Tangent;
	centroid float3 bitangent : Bitangent;
};
#endif

#ifdef CENTER_SHADING
struct VSOutput
{
	float4 position : SV_Position;
	float3 worldPos : WorldPos;
	float2 uv : TexCoord0;
	float3 viewDir : TexCoord1;
	float3 shadowCoord : TexCoord2;
	float3 normal : Normal;
	float3 tangent : Tangent;
	float3 bitangent : Bitangent;
};
#endif

struct MaterialConstants {
	float3 diffuse;
	float3 specular;
	float3 emissive;
	float shininess;
	uint textureMask;
};

Texture2D<float3> texDiffuse		: register(t0);
Texture2D<float3> texSpecular		: register(t1);
//Texture2D<float4> texEmissive		: register(t2);
Texture2D<float3> texNormal			: register(t3);
//Texture2D<float4> texLightmap		: register(t4);
//Texture2D<float4> texReflection	: register(t5);
StructuredBuffer<MaterialConstants>	materialBuffer	: register(t7);
Texture2D<float> texSSAO			: register(t64);
Texture2D<float> texShadow			: register(t65);

StructuredBuffer<LightData> lightBuffer : register(t66);
Texture2DArray<float> lightShadowArrayTex : register(t67);
ByteAddressBuffer lightGrid : register(t68);
ByteAddressBuffer lightGridBitMask : register(t69);

cbuffer PSConstants : register(b0)
{
	float3 SunDirection;
	float3 SunColor;
	float3 AmbientColor;
	float4 ShadowTexelSize;
	float4 InvTileDim;
	uint4 TileCount;
	uint4 FirstLightIndex;
	float3 DownSizedFactors;	// the factors to compensate resolution upsampling
								// in color shading PS, if we downsample the viewport by x, the screenPosition must be compensated for fetching full screen like SSAO and lightCull indices
								// the third parameter is the frame offset for odd or even pixel look up in the ssao and light grids
}

SamplerState sampler0 : register(s0);
SamplerComparisonState shadowSampler : register(s1);

cbuffer PSMaterialConstants : register(b1) {
	uint MaterialIdx;
}

void AntiAliasSpecular(inout float3 texNormal, inout float gloss)
{
	float normalLenSq = dot(texNormal, texNormal);
	float invNormalLen = rsqrt(normalLenSq);
	texNormal *= invNormalLen;
	gloss = lerp(1, gloss, rcp(invNormalLen));
}

// Apply fresnel to modulate the specular albedo
void FSchlick(inout float3 specular, inout float3 diffuse, float3 lightDir, float3 halfVec)
{
	float fresnel = pow(1.0 - saturate(dot(lightDir, halfVec)), 5.0);
	specular = lerp(specular, 1, fresnel);
	diffuse = lerp(diffuse, 0, fresnel);
}

float3 ApplyAmbientLight(
	float3	diffuse,	// Diffuse albedo
	float	ao,			// Pre-computed ambient-occlusion
	float3	lightColor	// Radiance of ambient light
)
{
	return ao * diffuse * lightColor;
}

float GetShadow(float3 ShadowCoord)
{
#ifdef SINGLE_SAMPLE
	float result = ShadowMap.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy, ShadowCoord.z);
#else
	const float Dilation = 2.0;
	float d1 = Dilation * ShadowTexelSize.x * 0.125;
	float d2 = Dilation * ShadowTexelSize.x * 0.875;
	float d3 = Dilation * ShadowTexelSize.x * 0.625;
	float d4 = Dilation * ShadowTexelSize.x * 0.375;
	float result = (
		2.0 * texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy, ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d2, d1), ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d1, -d2), ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d2, -d1), ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d1, d2), ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d4, d3), ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(-d3, -d4), ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d4, -d3), ShadowCoord.z) +
		texShadow.SampleCmpLevelZero(shadowSampler, ShadowCoord.xy + float2(d3, d4), ShadowCoord.z)
		) / 10.0;
#endif
	return result * result;
}

float GetShadowConeLight(uint lightIndex, float3 shadowCoord)
{
	float result = lightShadowArrayTex.SampleCmpLevelZero(
		shadowSampler, float3(shadowCoord.xy, lightIndex), shadowCoord.z);
	return result * result;
}

float3 ApplyLightCommon(
	float3	diffuseColor,	// Diffuse albedo
	float3	specularColor,	// Specular albedo
	float	specularMask,	// Where is it shiny or dingy?
	float	gloss,			// Specular power
	float3	normal,			// World-space normal
	float3	viewDir,		// World-space vector from eye to point
	float3	lightDir,		// World-space vector from point to light
	float3	lightColor		// Radiance of directional light
)
{
	float3 halfVec = normalize(lightDir - viewDir);
	float nDotH = saturate(dot(halfVec, normal));

	FSchlick(diffuseColor, specularColor, lightDir, halfVec);

	float specularFactor = specularMask * pow(nDotH, gloss) * (gloss + 2) / 8;

	float nDotL = saturate(dot(normal, lightDir));

	return nDotL * lightColor * (diffuseColor + specularFactor * specularColor);
}

float3 ApplyDirectionalLight(
	float3	diffuseColor,	// Diffuse albedo
	float3	specularColor,	// Specular albedo
	float	specularMask,	// Where is it shiny or dingy?
	float	gloss,			// Specular power
	float3	normal,			// World-space normal
	float3	viewDir,		// World-space vector from eye to point
	float3	lightDir,		// World-space vector from point to light
	float3	lightColor,		// Radiance of directional light
	float3	shadowCoord		// Shadow coordinate (Shadow map UV & light-relative Z)
)
{
	float shadow = GetShadow(shadowCoord);

	return shadow * ApplyLightCommon(
		diffuseColor,
		specularColor,
		specularMask,
		gloss,
		normal,
		viewDir,
		lightDir,
		lightColor
	);
}

float3 ApplyPointLight(
	float3	diffuseColor,	// Diffuse albedo
	float3	specularColor,	// Specular albedo
	float	specularMask,	// Where is it shiny or dingy?
	float	gloss,			// Specular power
	float3	normal,			// World-space normal
	float3	viewDir,		// World-space vector from eye to point
	float3	worldPos,		// World-space fragment position
	float3	lightPos,		// World-space light position
	float	lightRadiusSq,
	float3	lightColor		// Radiance of directional light
)
{
	float3 lightDir = lightPos - worldPos;
	float lightDistSq = dot(lightDir, lightDir);
	float invLightDist = rsqrt(lightDistSq);
	lightDir *= invLightDist;

	// modify 1/d^2 * R^2 to fall off at a fixed radius
	// (R/d)^2 - d/R = [(1/d^2) - (1/R^2)*(d/R)] * R^2
	float distanceFalloff = lightRadiusSq * (invLightDist * invLightDist);
	distanceFalloff = max(0, distanceFalloff - rsqrt(distanceFalloff));

	return distanceFalloff * ApplyLightCommon(
		diffuseColor,
		specularColor,
		specularMask,
		gloss,
		normal,
		viewDir,
		lightDir,
		lightColor
	);
}

float3 ApplyConeLight(
	float3	diffuseColor,	// Diffuse albedo
	float3	specularColor,	// Specular albedo
	float	specularMask,	// Where is it shiny or dingy?
	float	gloss,			// Specular power
	float3	normal,			// World-space normal
	float3	viewDir,		// World-space vector from eye to point
	float3	worldPos,		// World-space fragment position
	float3	lightPos,		// World-space light position
	float	lightRadiusSq,
	float3	lightColor,		// Radiance of directional light
	float3	coneDir,
	float2	coneAngles
)
{
	float3 lightDir = lightPos - worldPos;
	float lightDistSq = dot(lightDir, lightDir);
	float invLightDist = rsqrt(lightDistSq);
	lightDir *= invLightDist;

	// modify 1/d^2 * R^2 to fall off at a fixed radius
	// (R/d)^2 - d/R = [(1/d^2) - (1/R^2)*(d/R)] * R^2
	float distanceFalloff = lightRadiusSq * (invLightDist * invLightDist);
	distanceFalloff = max(0, distanceFalloff - rsqrt(distanceFalloff));

	float coneFalloff = dot(-lightDir, coneDir);
	coneFalloff = saturate((coneFalloff - coneAngles.y) * coneAngles.x);

	return (coneFalloff * distanceFalloff) * ApplyLightCommon(
		diffuseColor,
		specularColor,
		specularMask,
		gloss,
		normal,
		viewDir,
		lightDir,
		lightColor
	);
}

float3 ApplyConeShadowedLight(
	float3	diffuseColor,	// Diffuse albedo
	float3	specularColor,	// Specular albedo
	float	specularMask,	// Where is it shiny or dingy?
	float	gloss,			// Specular power
	float3	normal,			// World-space normal
	float3	viewDir,		// World-space vector from eye to point
	float3	worldPos,		// World-space fragment position
	float3	lightPos,		// World-space light position
	float	lightRadiusSq,
	float3	lightColor,		// Radiance of directional light
	float3	coneDir,
	float2	coneAngles,
	float4x4 shadowTextureMatrix,
	uint	lightIndex
)
{
	float4 shadowCoord = mul(shadowTextureMatrix, float4(worldPos, 1.0));
	shadowCoord.xyz *= rcp(shadowCoord.w);
	float shadow = GetShadowConeLight(lightIndex, shadowCoord.xyz);

	return shadow * ApplyConeLight(
		diffuseColor,
		specularColor,
		specularMask,
		gloss,
		normal,
		viewDir,
		worldPos,
		lightPos,
		lightRadiusSq,
		lightColor,
		coneDir,
		coneAngles
	);
}

// options for F+ variants and optimizations
#ifdef _WAVE_OP // SM 6.0 (new shader compiler)

// choose one of these:
//# define BIT_MASK
# define BIT_MASK_SORTED
//# define SCALAR_LOOP
//# define SCALAR_BRANCH

// enable to amortize latency of vector read in exchange for additional VGPRs being held
# define LIGHT_GRID_PRELOADING

// configured for 32 sphere lights, 64 cone lights, and 32 cone shadowed lights
# define POINT_LIGHT_GROUPS			1
# define SPOT_LIGHT_GROUPS			2
# define SHADOWED_SPOT_LIGHT_GROUPS	1
# define POINT_LIGHT_GROUPS_TAIL			POINT_LIGHT_GROUPS
# define SPOT_LIGHT_GROUPS_TAIL				POINT_LIGHT_GROUPS_TAIL + SPOT_LIGHT_GROUPS
# define SHADOWED_SPOT_LIGHT_GROUPS_TAIL	SPOT_LIGHT_GROUPS_TAIL + SHADOWED_SPOT_LIGHT_GROUPS


uint GetGroupBits(uint groupIndex, uint tileIndex, uint lightBitMaskGroups[4])
{
#ifdef LIGHT_GRID_PRELOADING
	return lightBitMaskGroups[groupIndex];
#else
	return lightGridBitMask.Load(tileIndex * 16 + groupIndex * 4);
#endif
}

uint64_t Ballot64(bool b)
{
	uint4 ballots = WaveActiveBallot(b);
	return (uint64_t)ballots.y << 32 | (uint64_t)ballots.x;
}

#endif // _WAVE_OP

// Helper function for iterating over a sparse list of bits.  Gets the offset of the next
// set bit, clears it, and returns the offset.
uint PullNextBit(inout uint bits)
{
	uint bitIndex = firstbitlow(bits);
	bits ^= 1 << bitIndex;
	return bitIndex;
}

// Main Pixel Shader
[RootSignature(ModelViewer_RootSig)]
float3 main(VSOutput vsOutput) : SV_Target0
{
	MaterialConstants matConstants = materialBuffer[MaterialIdx];

	uint2 pixelPos = vsOutput.position.xy * DownSizedFactors.xy;

#ifdef SAMPLE_SHADING
	uint flags = asuint(DownSizedFactors.z);

	// pixePos is used for the full res light grid look up
	// we need to account for the frame jitter
	pixelPos.x -= (flags & 0x1);;
	
	// On Intel pixel pos is always sample index 0 (bottom right)
	// so we back it up if this is sample index 1
	if ( flags & 0x02 ) // INTEL 
	{
		pixelPos.x -= (vsOutput.sampleIndex);
		pixelPos.y -= (vsOutput.sampleIndex);
	}
#endif

	// Texture Coordinate manipulation for CB sampling
	float2 tex2D = vsOutput.uv;
	float2 tdx = ddx_fine(tex2D);
	float2 tdy = ddy_fine(tex2D);

	float3 diffuseAlbedo = matConstants.diffuse;
	if (matConstants.textureMask & 1)
	{
		diffuseAlbedo = texDiffuse.SampleGrad(sampler0, vsOutput.uv, tdx * DDXY_BIAS, tdy * DDXY_BIAS);
	}

	//float3 colorSum = 0;
	float3 colorSum = matConstants.emissive;
	{
		float ao = texSSAO[pixelPos];
		colorSum += ApplyAmbientLight(diffuseAlbedo, ao, AmbientColor);
	}

	//float gloss = 128.0;
	float gloss = matConstants.shininess;;
	float3 normal = normalize(vsOutput.normal);
	if (dot(vsOutput.tangent, vsOutput.tangent) > 0.f)
	{
		normal = texNormal.SampleGrad(sampler0, vsOutput.uv, tdx * DDXY_BIAS, tdy * DDXY_BIAS) * 2.0 - 1.0;
		AntiAliasSpecular(normal, gloss);

		float3x3 tbn = float3x3(normalize(vsOutput.tangent), normalize(vsOutput.bitangent), normalize(vsOutput.normal));

		normal = normalize(mul(normal, tbn));
	}

	float3 specularAlbedo = float3(0.56, 0.56, 0.56);
	float specularMask = texSpecular.SampleGrad(sampler0, vsOutput.uv, tdx * DDXY_BIAS, tdy * DDXY_BIAS).g;
	
	float3 viewDir = normalize(vsOutput.viewDir);

	float3 shadowCoord = vsOutput.shadowCoord;
	colorSum += ApplyDirectionalLight(diffuseAlbedo, specularAlbedo, specularMask, gloss, normal, viewDir, SunDirection, SunColor, shadowCoord);

#ifdef ENABLE_LIGHT_GRID

	uint2 tilePos = GetTilePos(pixelPos, InvTileDim.xy);
	uint tileIndex = GetTileIndex(tilePos, TileCount.x);
	uint tileOffset = GetTileOffset(tileIndex);

	// Light Grid Preloading setup
	uint lightBitMaskGroups[4] = { 0, 0, 0, 0 };
#if defined(LIGHT_GRID_PRELOADING)
	uint4 lightBitMask = lightGridBitMask.Load4(tileIndex * 16);

	lightBitMaskGroups[0] = lightBitMask.x;
	lightBitMaskGroups[1] = lightBitMask.y;
	lightBitMaskGroups[2] = lightBitMask.z;
	lightBitMaskGroups[3] = lightBitMask.w;
#endif
	
	float3 worldPos = vsOutput.worldPos;

#define POINT_LIGHT_ARGS \
    diffuseAlbedo, \
    specularAlbedo, \
    specularMask, \
    gloss, \
    normal, \
    viewDir, \
    worldPos, \
	lightData.pos, \
    lightData.radiusSq, \
    lightData.color

	//vsOutput.worldPos, \

#define CONE_LIGHT_ARGS \
    POINT_LIGHT_ARGS, \
    lightData.coneDir, \
    lightData.coneAngles

#define SHADOWED_LIGHT_ARGS \
    CONE_LIGHT_ARGS, \
    lightData.shadowTextureMatrix, \
    lightIndex

#if defined(BIT_MASK)
	uint64_t threadMask = Ballot64(tileIndex != ~0); // attempt to get starting exec mask

	for (uint groupIndex = 0; groupIndex < 4; groupIndex++)
	{
		// combine across threads
		uint groupBits = WaveActiveBitOr(GetGroupBits(groupIndex, tileIndex, lightBitMaskGroups));

		while (groupBits != 0)
		{
			uint bitIndex = PullNextBit(groupBits);
			uint lightIndex = 32 * groupIndex + bitIndex;

			LightData lightData = lightBuffer[lightIndex];

			if (lightIndex < FirstLightIndex.x) // sphere
			{
				colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
			}
			else if (lightIndex < FirstLightIndex.y) // cone
			{
				colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
			}
			else // cone w/ shadow map
			{
				colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
			}
		}
	}

#elif defined(BIT_MASK_SORTED)

	// Get light type groups - these can be predefined as compile time constants to enable unrolling and better scheduling of vector reads
	uint pointLightGroupTail = POINT_LIGHT_GROUPS_TAIL;
	uint spotLightGroupTail = SPOT_LIGHT_GROUPS_TAIL;
	uint spotShadowLightGroupTail = SHADOWED_SPOT_LIGHT_GROUPS_TAIL;

	uint groupBitsMasks[4] = { 0, 0, 0, 0 };
	for (int i = 0; i < 4; i++)
	{
		// combine across threads
		groupBitsMasks[i] = WaveActiveBitOr(GetGroupBits(i, tileIndex, lightBitMaskGroups));
	}

	for (uint groupIndex = 0; groupIndex < pointLightGroupTail; groupIndex++)
	{
		uint groupBits = groupBitsMasks[groupIndex];

		while (groupBits != 0)
		{
			uint bitIndex = PullNextBit(groupBits);
			uint lightIndex = 32 * groupIndex + bitIndex;

			// sphere
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
		}
	}

	for (uint groupIndex = pointLightGroupTail; groupIndex < spotLightGroupTail; groupIndex++)
	{
		uint groupBits = groupBitsMasks[groupIndex];

		while (groupBits != 0)
		{
			uint bitIndex = PullNextBit(groupBits);
			uint lightIndex = 32 * groupIndex + bitIndex;

			// cone
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
		}
	}

	for (uint groupIndex = spotLightGroupTail; groupIndex < spotShadowLightGroupTail; groupIndex++)
	{
		uint groupBits = groupBitsMasks[groupIndex];

		while (groupBits != 0)
		{
			uint bitIndex = PullNextBit(groupBits);
			uint lightIndex = 32 * groupIndex + bitIndex;

			// cone w/ shadow map
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
		}
	}

#elif defined(SCALAR_LOOP)
	uint64_t threadMask = Ballot64(tileOffset != ~0); // attempt to get starting exec mask
	uint64_t laneBit = 1ull << WaveGetLaneIndex();

	while ((threadMask & laneBit) != 0) // is this thread waiting to be processed?
	{ // exec is now the set of remaining threads
	  // grab the tile offset for the first active thread
		uint uniformTileOffset = WaveReadLaneFirst(tileOffset);
		// mask of which threads have the same tile offset as the first active thread
		uint64_t uniformMask = Ballot64(tileOffset == uniformTileOffset);

		if (any((uniformMask & laneBit) != 0)) // is this thread one of the current set of uniform threads?
		{
			uint tileLightCount = lightGrid.Load(uniformTileOffset + 0);
			uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
			uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
			uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

			uint tileLightLoadOffset = uniformTileOffset + 4;

			// sphere
			for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
			{
				uint lightIndex = lightGrid.Load(tileLightLoadOffset);
				LightData lightData = lightBuffer[lightIndex];
				colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
			}

			// cone
			for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
			{
				uint lightIndex = lightGrid.Load(tileLightLoadOffset);
				LightData lightData = lightBuffer[lightIndex];
				colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
			}

			// cone w/ shadow map
			for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
			{
				uint lightIndex = lightGrid.Load(tileLightLoadOffset);
				LightData lightData = lightBuffer[lightIndex];
				colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
			}
		}

		// strip the current set of uniform threads from the exec mask for the next loop iteration
		threadMask &= ~uniformMask;
	}

#elif defined(SCALAR_BRANCH)

	if (Ballot64(tileOffset == WaveReadLaneFirst(tileOffset)) == ~0ull)
	{
		// uniform branch
		tileOffset = WaveReadLaneFirst(tileOffset);

		uint tileLightCount = lightGrid.Load(tileOffset + 0);
		uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
		uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
		uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

		uint tileLightLoadOffset = tileOffset + 4;

		// sphere
		for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
		{
			uint lightIndex = lightGrid.Load(tileLightLoadOffset);
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
		}

		// cone
		for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
		{
			uint lightIndex = lightGrid.Load(tileLightLoadOffset);
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
		}

		// cone w/ shadow map
		for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
		{
			uint lightIndex = lightGrid.Load(tileLightLoadOffset);
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
		}
	}
	else
	{
		// divergent branch
		uint tileLightCount = lightGrid.Load(tileOffset + 0);
		uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
		uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
		uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

		uint tileLightLoadOffset = tileOffset + 4;

		// sphere
		for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
		{
			uint lightIndex = lightGrid.Load(tileLightLoadOffset);
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
		}

		// cone
		for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
		{
			uint lightIndex = lightGrid.Load(tileLightLoadOffset);
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
		}

		// cone w/ shadow map
		for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
		{
			uint lightIndex = lightGrid.Load(tileLightLoadOffset);
			LightData lightData = lightBuffer[lightIndex];
			colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
		}
	}

#else // SM 5.0 (no wave intrinsics)

	uint tileLightCount = lightGrid.Load(tileOffset + 0);
	uint tileLightCountSphere = (tileLightCount >> 0) & 0xff;
	uint tileLightCountCone = (tileLightCount >> 8) & 0xff;
	uint tileLightCountConeShadowed = (tileLightCount >> 16) & 0xff;

	uint tileLightLoadOffset = tileOffset + 4;

	// sphere
	for (uint n = 0; n < tileLightCountSphere; n++, tileLightLoadOffset += 4)
	{
		uint lightIndex = lightGrid.Load(tileLightLoadOffset);
		LightData lightData = lightBuffer[lightIndex];
		colorSum += ApplyPointLight(POINT_LIGHT_ARGS);
	}

	// cone
	for (uint n = 0; n < tileLightCountCone; n++, tileLightLoadOffset += 4)
	{
		uint lightIndex = lightGrid.Load(tileLightLoadOffset);
		LightData lightData = lightBuffer[lightIndex];
		colorSum += ApplyConeLight(CONE_LIGHT_ARGS);
	}

	// cone w/ shadow map
	for (uint n = 0; n < tileLightCountConeShadowed; n++, tileLightLoadOffset += 4)
	{
		uint lightIndex = lightGrid.Load(tileLightLoadOffset);
		LightData lightData = lightBuffer[lightIndex];
		colorSum += ApplyConeShadowedLight(SHADOWED_LIGHT_ARGS);
	}
#endif

#endif // enable light grid

	//return specularMask;
	//return diffuseAlbedo;
	return colorSum;
}
