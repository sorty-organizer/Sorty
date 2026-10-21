//
//  WelcomeStepView.swift
//  Sorty
//
//  Welcome step of the onboarding flow
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

// MARK: - Welcome Step View

public struct WelcomeStepView: View {
    @SortyHotReload private var hotReload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var revealScale: CGFloat = 0.05
    @State private var revealOpacity: Double = 0
    @State private var backgroundRevealed = false
    @State private var hasAppeared = false
    @State private var featuresAppeared = false
    @State private var showGlowRing = false
    @State private var showParticles = false
    @State private var hasPlayedSound = false
    @State private var animationTask: Task<Void, Never>?
    @StateObject private var revealAudio = WelcomeRevealAudio()
    @StateObject private var onboardingAudio = OnboardingAudioManager()

    public init() {}

    public var body: some View {
        ZStack {
            // Base dark layer
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            // Reveal gradient blob - expands from center
            RevealGradientBlob(scale: revealScale, opacity: revealOpacity)
                .allowsHitTesting(false)

            // Ambient gradient (fades in after reveal)
            AnimatedGradientBackground(revealed: backgroundRevealed)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Floating particles (appear after reveal). Size and lane are
            // seeded from the index so parent re-renders never re-randomize them.
            welcomeParticles
            // Content
            welcomeContent
        }
        .onAppear {
            startRevealSequence()
        }
        .onDisappear {
            animationTask?.cancel()
            animationTask = nil
            revealAudio.stop()
            onboardingAudio.stopAll()
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                settleRevealSequence()
            }
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome Step")
    }

    private func startRevealSequence() {
        animationTask?.cancel()

        // Phase 1: Gradient blob reveal (0 - 0.8s)
        revealAudio.playRevealSwell()
        onboardingAudio.startBackgroundMelody()

        guard !reduceMotion else {
            settleRevealSequence()
            return
        }

        withAnimation(.easeOut(duration: 1.0)) {
            revealScale = 1.2
            revealOpacity = 1.0
        }

        // Phase 2+: async sequence stored for cancellation on disappear
        animationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 1.2)) {
                backgroundRevealed = true
                revealOpacity = 0.3
                revealScale = 1.5
            }

            // Phase 3: Content appears (0.6s)
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) {
                hasAppeared = true
                showGlowRing = true
            }

            // Play sparkle sound as icon appears
            if !hasPlayedSound {
                if let sound = NSSound(named: "Glass") {
                    sound.volume = 0.15
                    sound.play()
                }
                hasPlayedSound = true
            }

            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Phase 4: Particles and features
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.8)) {
                showParticles = true
            }

            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
                featuresAppeared = true
            }
        }
    }

    private func settleRevealSequence() {
        animationTask?.cancel()
        animationTask = nil
        withAnimation(nil) {
            revealScale = 1.5
            revealOpacity = 0.3
            backgroundRevealed = true
            hasAppeared = true
            featuresAppeared = true
            showGlowRing = true
            showParticles = false
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                ZStack {
                    GlowRing(isActive: showGlowRing)

                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 104, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .shadow(color: .purple.opacity(hasAppeared ? 0.25 : 0), radius: 20, x: 0, y: 8)
                        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
                }
                .scaleEffect(hasAppeared ? 1 : 0.3)
                .opacity(hasAppeared ? 1 : 0)
                .animation(.spring(response: 0.9, dampingFraction: 0.7).delay(0.6), value: hasAppeared)

                VStack(spacing: 12) {
                    Text("Welcome to Sorty")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 20)
                        .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.9), value: hasAppeared)

                    Text("Sorty-powered file organization for your Mac")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 15)
                        .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.1), value: hasAppeared)
                }
            }

            Spacer()
                .frame(height: 24)

            welcomeFeatures
            Spacer()
                .frame(height: 16)

            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 18))

                Text("Before organizing, always ensure you have backups of important files.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: 460)
            .systemLiquidGlassBackground(cornerRadius: 12)
            .opacity(featuresAppeared ? 1 : 0)
            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(2.1), value: featuresAppeared)

            Spacer()
        }
    }

    private var welcomeFeatures: some View {
        VStack(alignment: .leading, spacing: 12) {
            WelcomeFeatureRow(
                icon: "wand.and.stars",
                iconColor: .purple,
                title: "Smart Organization",
                description: "Sorty analyzes your files and creates a logical folder structure"
            )
            .opacity(featuresAppeared ? 1 : 0)
            .offset(x: featuresAppeared ? 0 : -30)
            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.3), value: featuresAppeared)

            WelcomeFeatureRow(
                icon: "lock.shield.fill",
                iconColor: .green,
                title: "Privacy Focused",
                description: "File names and metadata are sent to Sorty for organization - file contents stay on your Mac unless Deep Scan is enabled"
            )
            .opacity(featuresAppeared ? 1 : 0)
            .offset(x: featuresAppeared ? 0 : -30)
            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.5), value: featuresAppeared)

            WelcomeFeatureRow(
                icon: "arrow.uturn.backward.circle.fill",
                iconColor: .blue,
                title: "Fully Reversible",
                description: "Every change can be undone with a single click"
            )
            .opacity(featuresAppeared ? 1 : 0)
            .offset(x: featuresAppeared ? 0 : -30)
            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.7), value: featuresAppeared)

            WelcomeFeatureRow(
                icon: "person.crop.circle.badge.checkmark",
                iconColor: .orange,
                title: "Custom Workflows",
                description: "Create personas tailored to your specific organization needs"
            )
            .opacity(featuresAppeared ? 1 : 0)
            .offset(x: featuresAppeared ? 0 : -30)
            .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(1.9), value: featuresAppeared)
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 40)
    }

    private func particleSize(for index: Int) -> CGFloat {
        3 + CGFloat((index * 37 + 11) % 30) / 10
    }

    private func particleXPosition(for index: Int) -> CGFloat {
        CGFloat((index * 137 + 43) % 400) - 200
    }

    @ViewBuilder
    private var welcomeParticles: some View {
        if showParticles {
            ZStack {
                ForEach(0..<7, id: \.self) { i in
                    FloatingParticle(
                        delay: Double(i) * 0.4,
                        size: particleSize(for: i),
                        xPosition: particleXPosition(for: i)
                    )
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

// MARK: - Welcome Feature Row

struct WelcomeFeatureRow: View {
    @SortyHotReload private var hotReload
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    var badge: String? = nil

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(title))
                        .font(.headline)

                    if let badge {
                        OnboardingCapsuleBadge(text: badge)
                    }
                }

                Text(LocalizedStringKey(description))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .systemLiquidGlassBackground(cornerRadius: 14)
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    WelcomeStepView()
}
