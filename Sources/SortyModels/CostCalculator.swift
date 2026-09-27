//
//  CostCalculator.swift
//  Sorty
//
//  Utility for estimating API costs based on token usage
//

import Foundation

public enum CostCalculator {
    /// Pricing per 1,000,000 tokens in USD
    struct ModelPricing {
        let inputPrice: Decimal
        let outputPrice: Decimal
    }
    
    // Ordered from most specific to more general pattern matches.
    private static let pricingPatterns: [(pattern: String, pricing: ModelPricing)] = [
        // OpenAI (2026-era model family)
        ("gpt-5.4-mini", ModelPricing(inputPrice: 0.40, outputPrice: 1.60)),
        ("gpt-5.4-nano", ModelPricing(inputPrice: 0.08, outputPrice: 0.32)),
        ("gpt-5.4", ModelPricing(inputPrice: 2.50, outputPrice: 10.00)),
        ("gpt-5-mini", ModelPricing(inputPrice: 0.40, outputPrice: 1.60)),
        ("gpt-5-nano", ModelPricing(inputPrice: 0.08, outputPrice: 0.32)),
        ("gpt-5", ModelPricing(inputPrice: 2.50, outputPrice: 10.00)),
        ("gpt-4.1-mini", ModelPricing(inputPrice: 0.40, outputPrice: 1.60)),
        ("gpt-4.1-nano", ModelPricing(inputPrice: 0.10, outputPrice: 0.40)),
        ("gpt-4.1", ModelPricing(inputPrice: 2.00, outputPrice: 8.00)),
        ("gpt-4o-mini", ModelPricing(inputPrice: 0.15, outputPrice: 0.60)),
        ("gpt-4o", ModelPricing(inputPrice: 5.00, outputPrice: 15.00)),
        ("gpt-4-turbo", ModelPricing(inputPrice: 10.00, outputPrice: 30.00)),
        ("gpt-3.5-turbo", ModelPricing(inputPrice: 0.50, outputPrice: 1.50)),

        // Anthropic
        ("claude-opus-4-6", ModelPricing(inputPrice: 15.00, outputPrice: 75.00)),
        ("claude-opus-4.6", ModelPricing(inputPrice: 15.00, outputPrice: 75.00)),
        ("claude-opus-4", ModelPricing(inputPrice: 15.00, outputPrice: 75.00)),
        ("claude-sonnet-4-6", ModelPricing(inputPrice: 3.00, outputPrice: 15.00)),
        ("claude-sonnet-4.6", ModelPricing(inputPrice: 3.00, outputPrice: 15.00)),
        ("claude-sonnet-4", ModelPricing(inputPrice: 3.00, outputPrice: 15.00)),
        ("claude-haiku-4-5", ModelPricing(inputPrice: 1.00, outputPrice: 5.00)),
        ("claude-haiku-4.5", ModelPricing(inputPrice: 1.00, outputPrice: 5.00)),
        ("claude-3-5-sonnet", ModelPricing(inputPrice: 3.00, outputPrice: 15.00)),
        ("claude-3-opus", ModelPricing(inputPrice: 15.00, outputPrice: 75.00)),
        ("claude-3-haiku", ModelPricing(inputPrice: 0.25, outputPrice: 1.25)),

        // Gemini
        ("gemini-3.1-pro-preview", ModelPricing(inputPrice: 3.50, outputPrice: 10.50)),
        ("gemini-3.1-pro", ModelPricing(inputPrice: 3.50, outputPrice: 10.50)),
        ("gemini-3.1-flash-lite-preview", ModelPricing(inputPrice: 0.08, outputPrice: 0.30)),
        ("gemini-3-flash-preview", ModelPricing(inputPrice: 0.10, outputPrice: 0.40)),
        ("gemini-3-flash", ModelPricing(inputPrice: 0.10, outputPrice: 0.40)),
        ("gemini-2.5-pro", ModelPricing(inputPrice: 3.50, outputPrice: 10.50)),
        ("gemini-2.5-flash-lite", ModelPricing(inputPrice: 0.08, outputPrice: 0.30)),
        ("gemini-2.5-flash", ModelPricing(inputPrice: 0.10, outputPrice: 0.40)),
        ("gemini-1.5-pro", ModelPricing(inputPrice: 3.50, outputPrice: 10.50)),
        ("gemini-1.5-flash", ModelPricing(inputPrice: 0.075, outputPrice: 0.30)),

        // Groq / Open-source hosted models (rough estimates)
        ("openai/gpt-oss-120b", ModelPricing(inputPrice: 0.60, outputPrice: 1.80)),
        ("openai/gpt-oss-20b", ModelPricing(inputPrice: 0.15, outputPrice: 0.60)),
        ("llama-3.3-70b", ModelPricing(inputPrice: 0.59, outputPrice: 0.79)),
        ("llama-3.1-8b", ModelPricing(inputPrice: 0.05, outputPrice: 0.10)),
        ("qwen3-32b", ModelPricing(inputPrice: 0.29, outputPrice: 0.59)),

        // Ollama/local models default to no API cost
        ("llama3.1", ModelPricing(inputPrice: 0, outputPrice: 0)),
        ("qwen3.5", ModelPricing(inputPrice: 0, outputPrice: 0)),
        ("qwen3", ModelPricing(inputPrice: 0, outputPrice: 0)),
        ("deepseek-r1", ModelPricing(inputPrice: 0, outputPrice: 0)),
        ("gemma3", ModelPricing(inputPrice: 0, outputPrice: 0)),
        ("llama4", ModelPricing(inputPrice: 0, outputPrice: 0)),
        ("mistral", ModelPricing(inputPrice: 0, outputPrice: 0)),

        // Legacy keys for backward compatibility
        ("llama3-70b", ModelPricing(inputPrice: 0.59, outputPrice: 0.79)),
        ("llama3-8b", ModelPricing(inputPrice: 0.05, outputPrice: 0.10))
    ]
    
    /// Fallback pricing for unknown models (conservative estimate)
    private static let baselinePricing = ModelPricing(inputPrice: 1.00, outputPrice: 2.00)
    
    /// Calculate estimated cost in USD
    public static func calculate(model: String, inputTokens: Int, outputTokens: Int) -> Decimal {
        let normalizedModel = model.lowercased()
        let pricing = pricingPatterns.first { normalizedModel.contains($0.pattern) }?.pricing ?? baselinePricing
        
        let inputCost = (Decimal(inputTokens) / 1_000_000) * pricing.inputPrice
        let outputCost = (Decimal(outputTokens) / 1_000_000) * pricing.outputPrice
        
        return inputCost + outputCost
    }
}
