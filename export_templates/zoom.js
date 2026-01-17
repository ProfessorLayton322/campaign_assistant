// Zoom functionality for campaign assistant
(function() {
	function initZoom() {
		const canvas = document.getElementById('canvas');
		if (!canvas) return;

		// Create container wrapper
		const container = document.createElement('div');
		container.id = 'canvas-container';
		container.style.cssText = 'width:100%;height:100%;overflow:hidden;display:flex;align-items:center;justify-content:center;';
		canvas.parentNode.insertBefore(container, canvas);
		container.appendChild(canvas);
		canvas.style.transformOrigin = 'center center';

		let scale = 1;
		let translateX = 0;
		let translateY = 0;
		const minScale = 0.5;
		const maxScale = 5;

		function updateTransform() {
			canvas.style.transform = `translate(${translateX}px, ${translateY}px) scale(${scale})`;
		}

		// Desktop: Ctrl + mouse wheel zoom
		container.addEventListener('wheel', function(e) {
			if (e.ctrlKey) {
				e.preventDefault();

				const rect = container.getBoundingClientRect();
				const mouseX = e.clientX - rect.left - rect.width / 2;
				const mouseY = e.clientY - rect.top - rect.height / 2;

				const delta = e.deltaY > 0 ? 0.9 : 1.1;
				const newScale = Math.min(maxScale, Math.max(minScale, scale * delta));

				if (newScale !== scale) {
					const scaleChange = newScale / scale;
					translateX = mouseX - (mouseX - translateX) * scaleChange;
					translateY = mouseY - (mouseY - translateY) * scaleChange;
					scale = newScale;
					updateTransform();
				}
			}
		}, { passive: false });

		// Mobile: Pinch to zoom
		let initialDistance = 0;
		let initialScale = 1;
		let initialTranslateX = 0;
		let initialTranslateY = 0;
		let initialMidpoint = { x: 0, y: 0 };

		container.addEventListener('touchstart', function(e) {
			if (e.touches.length === 2) {
				e.preventDefault();
				const touch1 = e.touches[0];
				const touch2 = e.touches[1];
				initialDistance = Math.hypot(touch2.clientX - touch1.clientX, touch2.clientY - touch1.clientY);
				initialScale = scale;
				initialTranslateX = translateX;
				initialTranslateY = translateY;

				const rect = container.getBoundingClientRect();
				initialMidpoint = {
					x: (touch1.clientX + touch2.clientX) / 2 - rect.left - rect.width / 2,
					y: (touch1.clientY + touch2.clientY) / 2 - rect.top - rect.height / 2
				};
			}
		}, { passive: false });

		container.addEventListener('touchmove', function(e) {
			if (e.touches.length === 2) {
				e.preventDefault();
				const touch1 = e.touches[0];
				const touch2 = e.touches[1];
				const currentDistance = Math.hypot(touch2.clientX - touch1.clientX, touch2.clientY - touch1.clientY);

				const newScale = Math.min(maxScale, Math.max(minScale, initialScale * (currentDistance / initialDistance)));

				if (newScale !== scale) {
					const scaleChange = newScale / initialScale;
					translateX = initialMidpoint.x - (initialMidpoint.x - initialTranslateX) * scaleChange;
					translateY = initialMidpoint.y - (initialMidpoint.y - initialTranslateY) * scaleChange;
					scale = newScale;
					updateTransform();
				}
			}
		}, { passive: false });

		// Double-tap to reset zoom
		let lastTap = 0;
		container.addEventListener('touchend', function(e) {
			const now = Date.now();
			if (now - lastTap < 300 && e.touches.length === 0) {
				scale = 1;
				translateX = 0;
				translateY = 0;
				updateTransform();
			}
			lastTap = now;
		});
	}

	// Wait for game to load, then init zoom
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', function() {
			setTimeout(initZoom, 1000);
		});
	} else {
		setTimeout(initZoom, 1000);
	}
})();
